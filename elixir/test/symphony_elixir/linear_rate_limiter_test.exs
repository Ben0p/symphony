defmodule SymphonyElixir.Linear.RateLimiterTest do
  use ExUnit.Case, async: false

  @moduletag skip:
               if(
                 match?({:unix, _name}, :os.type()) and is_binary(System.find_executable("flock")),
                 do: false,
                 else: "requires the managed Unix flock primitive"
               )

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Linear.RateLimiter

  setup do
    state_path = Path.join(System.tmp_dir!(), "symphony-linear-rate-limit-test-#{System.unique_integer([:positive])}.state")

    tracker_settings = %{
      provider: %{
        "rate_limit_file" => state_path,
        "rate_limit_min_interval_ms" => 50,
        "rate_limit_max_wait_ms" => 1_000,
        "rate_limit_max_retry_after_ms" => 100
      }
    }

    on_exit(fn ->
      File.rm(state_path)
      File.rm(state_path <> ".lock")
    end)

    {:ok, tracker_settings: tracker_settings}
  end

  test "reserves a shared minimum interval", %{tracker_settings: tracker_settings} do
    assert :ok = RateLimiter.await(tracker_settings)

    started_at = System.monotonic_time(:millisecond)
    assert :ok = RateLimiter.await(tracker_settings)

    assert System.monotonic_time(:millisecond) - started_at >= 35
  end

  test "serializes concurrent callers through the shared state file", %{tracker_settings: tracker_settings} do
    parent = self()

    tasks =
      1..3
      |> Enum.map(fn _ ->
        Task.async(fn ->
          send(parent, {:rate_limiter_ready, self()})

          receive do
            :start ->
              assert :ok = RateLimiter.await(tracker_settings)
              System.monotonic_time(:millisecond)
          end
        end)
      end)

    Enum.each(tasks, fn _task ->
      assert_receive {:rate_limiter_ready, _pid}, 1_000
    end)

    started_at = System.monotonic_time(:millisecond)
    Enum.each(tasks, fn %Task{pid: pid} -> send(pid, :start) end)

    timestamps =
      tasks
      |> Enum.map(&Task.await(&1, 2_000))
      |> Enum.sort()

    assert Enum.max(timestamps) - started_at >= 70
  end

  test "serializes reservations across independent BEAM OS processes", %{tracker_settings: tracker_settings} do
    state_path = tracker_settings.provider["rate_limit_file"]
    result_paths = Enum.map(1..2, fn index -> "#{state_path}.process-#{index}" end)
    ready_paths = Enum.map(result_paths, &(&1 <> ".ready"))
    barrier_path = state_path <> ".start"
    executable = System.find_executable("elixir")

    ports =
      Enum.zip(result_paths, ready_paths)
      |> Enum.map(fn {result_path, ready_path} ->
        start_external_reservation(executable, state_path, result_path, ready_path, barrier_path)
      end)

    on_exit(fn ->
      Enum.each(ports, &close_external_port/1)
      Enum.each(result_paths ++ ready_paths ++ [barrier_path], &File.rm/1)
    end)

    assert :ok = await_files(ready_paths, 5_000)
    assert :ok = File.write(barrier_path, "start")
    Enum.each(ports, fn port -> assert :ok = await_external_process(port, 5_000) end)

    results = Enum.map(result_paths, fn path -> path |> File.read!() |> String.split("\n", trim: true) end)
    assert Enum.all?(results, &(List.first(&1) == ":ok"))

    timestamps = Enum.map(results, &(&1 |> List.last() |> String.to_integer()))

    assert abs(Enum.at(timestamps, 0) - Enum.at(timestamps, 1)) >= 90
  end

  test "waits for a live kernel lock holder", %{tracker_settings: tracker_settings} do
    port = start_advisory_lock(tracker_settings, self(), 175, "-TERM")
    started_at = System.monotonic_time(:millisecond)
    assert :ok = RateLimiter.await(tracker_settings)
    assert System.monotonic_time(:millisecond) - started_at >= 150
    assert_receive {:advisory_lock_killed, ^port}, 2_000
  end

  test "reacquires after a kernel lock holder crashes", %{tracker_settings: tracker_settings} do
    port = start_advisory_lock(tracker_settings, self(), 175, "-KILL")
    started_at = System.monotonic_time(:millisecond)
    assert :ok = RateLimiter.await(tracker_settings)
    assert System.monotonic_time(:millisecond) - started_at >= 150
    assert_receive {:advisory_lock_killed, ^port}, 2_000
  end

  test "times out while a holder is alive and reacquires after release", %{tracker_settings: tracker_settings} do
    tracker_settings =
      put_in(tracker_settings, [:provider, "rate_limit_max_wait_ms"], 75)
      |> put_in([:provider, "rate_limit_min_interval_ms"], 0)

    port = start_advisory_lock(tracker_settings, self(), 250, "-KILL")
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :linear_rate_limit_lock_timeout} = RateLimiter.await(tracker_settings)
    assert System.monotonic_time(:millisecond) - started_at < 220
    assert_receive {:advisory_lock_killed, ^port}, 2_000
    assert :ok = RateLimiter.await(tracker_settings)
  end

  test "honors a bounded retry-after cooldown", %{tracker_settings: tracker_settings} do
    assert :ok = RateLimiter.observe_response(tracker_settings, %{status: 429, headers: [{"retry-after", "1"}]})

    started_at = System.monotonic_time(:millisecond)
    assert :ok = RateLimiter.await(tracker_settings)

    assert System.monotonic_time(:millisecond) - started_at >= 75
  end

  test "honors a GraphQL rate-limit window embedded in a non-429 response", %{tracker_settings: tracker_settings} do
    tracker_settings =
      put_in(tracker_settings, [:provider, "rate_limit_max_retry_after_ms"], 3_600_000)

    response = %{
      status: 400,
      body: %{
        "errors" => [
          %{
            "type" => "ratelimited",
            "extensions" => %{
              "statusCode" => 429,
              "meta" => %{"rateLimitResult" => %{"duration" => 3_600_000}}
            }
          }
        ]
      }
    }

    assert :ok = RateLimiter.observe_response(tracker_settings, response)
    assert {:error, :linear_rate_limit_wait_exceeded} = RateLimiter.await(tracker_settings)
  end

  test "persists a GraphQL cooldown when the client returns an ok response tuple", %{tracker_settings: tracker_settings} do
    tracker_settings =
      Map.merge(tracker_settings, %{
        api_key: "test-linear-token",
        endpoint: "https://linear.invalid/graphql",
        provider: put_in(tracker_settings.provider, ["rate_limit_max_retry_after_ms"], 3_600_000)
      })

    response = %{
      status: 400,
      body: %{
        "errors" => [
          %{
            "type" => "ratelimited",
            "extensions" => %{
              "statusCode" => 429,
              "meta" => %{"rateLimitResult" => %{"duration" => 3_600_000}}
            }
          }
        ]
      }
    }

    assert {:error, {:linear_api_status, 400}} =
             Client.graphql("query Test { viewer { id } }", %{},
               tracker_settings: tracker_settings,
               request_fun: fn _payload, _headers -> {:ok, response} end
             )

    assert {:ok, next_allowed_at} = File.read(tracker_settings.provider["rate_limit_file"])
    assert String.to_integer(String.trim(next_allowed_at)) >= System.system_time(:millisecond) + 3_599_000
  end

  defp start_advisory_lock(tracker_settings, parent, hold_ms, signal) do
    path = tracker_settings.provider["rate_limit_file"] <> ".lock"
    executable = System.find_executable("flock")

    command = "printf 'symphony-test-rate-lock-ready'; while read _line; do :; done"

    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, :exit_status, {:args, ["-F", "-x", "-w", "5", path, "-c", command]}]
      )

    receive do
      {^port, {:data, "symphony-test-rate-lock-ready"}} ->
        :ok
    after
      1_000 ->
        flunk("advisory lock helper did not acquire the lock")
    end

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    spawn(fn ->
      Process.sleep(hold_ms)
      {_output, 0} = System.cmd("kill", [signal, Integer.to_string(os_pid)])
      send(parent, {:advisory_lock_killed, port})
    end)

    port
  end

  defp start_external_reservation(executable, state_path, result_path, ready_path, barrier_path) do
    code = ~S"""
    state_path = Enum.at(System.argv(), 0)
    result_path = Enum.at(System.argv(), 1)
    ready_path = Enum.at(System.argv(), 2)
    barrier_path = Enum.at(System.argv(), 3)

    File.write!(ready_path, "ready")

    wait_for_barrier = fn wait_for_barrier ->
      if File.exists?(barrier_path) do
        :ok
      else
        Process.sleep(5)
        wait_for_barrier.(wait_for_barrier)
      end
    end

    wait_for_barrier.(wait_for_barrier)

    settings = %{
      provider: %{
        "rate_limit_file" => state_path,
        "rate_limit_min_interval_ms" => 120,
        "rate_limit_max_wait_ms" => 2_000
      }
    }

    result = SymphonyElixir.Linear.RateLimiter.await(settings)
    File.write!(result_path, inspect(result) <> "\n" <> Integer.to_string(System.system_time(:millisecond)))
    """

    Port.open(
      {:spawn_executable, executable},
      [
        :binary,
        :exit_status,
        {:args,
         [
           "-pa",
           Application.app_dir(:symphony_elixir, "ebin"),
           "-e",
           code,
           "--",
           state_path,
           result_path,
           ready_path,
           barrier_path
         ]}
      ]
    )
  end

  defp await_files(paths, timeout_ms) when timeout_ms > 0 do
    if Enum.all?(paths, &File.exists?/1) do
      :ok
    else
      Process.sleep(10)
      await_files(paths, timeout_ms - 10)
    end
  end

  defp await_files(_paths, _timeout_ms), do: {:error, :timeout}

  defp await_external_process(port, timeout_ms) do
    receive do
      {^port, {:data, _data}} -> await_external_process(port, timeout_ms)
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, status}} -> {:error, {:exit_status, status}}
    after
      timeout_ms -> {:error, :timeout}
    end
  end

  defp close_external_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    _error -> :ok
  end
end
