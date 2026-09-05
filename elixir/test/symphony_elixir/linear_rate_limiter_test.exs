defmodule SymphonyElixir.Linear.RateLimiterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Linear.RateLimiter

  setup do
    state_path = Path.join(System.tmp_dir!(), "symphony-linear-rate-limit-test-#{System.unique_integer([:positive])}.state")

    tracker_settings = %{
      provider: %{
        "rate_limit_file" => state_path,
        "rate_limit_min_interval_ms" => 50,
        "rate_limit_max_wait_ms" => 1_000,
        "rate_limit_stale_lock_ms" => 100,
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

  test "does not evict a live lock after its stale interval", %{tracker_settings: tracker_settings} do
    lock_path = tracker_settings.provider["rate_limit_file"] <> ".lock"
    parent = self()

    owner =
      Task.async(fn ->
        {:ok, io} = File.open(lock_path, [:write, :exclusive, :binary])

        metadata =
          [
            "symphony-linear-rate-lock-v1",
            to_string(:os.getpid()),
            Integer.to_string(System.system_time(:millisecond)),
            "test-owner"
          ]
          |> Enum.join("\n")

        :ok = IO.binwrite(io, metadata)
        :ok = File.touch(lock_path, System.system_time(:second) - 1)
        send(parent, :live_lock_ready)
        Process.sleep(175)
        File.close(io)
        File.rm(lock_path)
      end)

    assert_receive :live_lock_ready, 1_000
    started_at = System.monotonic_time(:millisecond)
    assert :ok = RateLimiter.await(tracker_settings)
    assert System.monotonic_time(:millisecond) - started_at >= 150
    assert :ok = Task.await(owner, 2_000)
  end

  test "does not evict an incomplete live lock after its stale interval", %{tracker_settings: tracker_settings} do
    lock_path = tracker_settings.provider["rate_limit_file"] <> ".lock"
    parent = self()

    owner =
      Task.async(fn ->
        {:ok, io} = File.open(lock_path, [:write, :exclusive, :binary])
        :ok = File.touch(lock_path, System.system_time(:second) - 1)
        send(parent, :incomplete_lock_ready)
        Process.sleep(175)
        File.close(io)
        File.rm(lock_path)
      end)

    assert_receive :incomplete_lock_ready, 1_000
    started_at = System.monotonic_time(:millisecond)
    assert :ok = RateLimiter.await(tracker_settings)
    assert System.monotonic_time(:millisecond) - started_at >= 150
    assert :ok = Task.await(owner, 2_000)
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
end
