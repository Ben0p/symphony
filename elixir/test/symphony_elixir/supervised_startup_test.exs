defmodule SymphonyElixir.Codex.SupervisedStartupTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.SupervisedStartup
  alias SymphonyElixir.ExecutionSupervisor

  test "waits for delayed scope visibility without consuming or reordering port data" do
    port = open_port("read line")
    send(self(), {port, {:data, {:noeol, "first"}}})
    send(self(), {port, {:data, {:eol, "second"}}})
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    capture = fn identity, opts ->
      assert opts[:timeout_ms] > 0

      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:error, {:systemd_unit_not_loaded, "not-found"}}
        1 -> {:error, {:systemd_unit_not_active, "inactive"}}
        _ -> {:ok, captured(identity)}
      end
    end

    assert {:ok, identity} = SupervisedStartup.capture(port, identity(), fn -> :ok end, capture: capture)
    assert identity.main_pid == nil
    assert Agent.get(calls, & &1) == 3
    assert_receive {^port, {:data, {:noeol, "first"}}}
    assert_receive {^port, {:data, {:eol, "second"}}}
    Port.close(port)
  end

  test "retains output hashes and fails on an actual early port exit" do
    port = open_port("printf private-diagnostic; exit 7")
    capture = fn _, _ -> {:error, {:systemd_unit_not_loaded, "not-found"}} end

    assert {:error, {:supervisor_startup_failed, {:supervisor_port_exited, 7}, summary}, nil} =
             SupervisedStartup.capture(port, identity(), fn -> :ok end, capture: capture)

    assert summary.bytes == byte_size("private-diagnostic")
    assert summary.chunk_sha256 == [Base.encode16(:crypto.hash(:sha256, "private-diagnostic"), case: :lower)]
    refute inspect(summary) =~ "private-diagnostic"
  end

  test "pause during startup fails closed without another capture" do
    port = open_port("read line")
    {:ok, checks} = Agent.start_link(fn -> 0 end)

    guard = fn ->
      if Agent.get_and_update(checks, &{&1, &1 + 1}) == 0, do: :ok, else: {:error, :global_pause}
    end

    capture = fn _, _ -> {:error, {:systemd_unit_not_loaded, "not-found"}} end

    assert {:error, {:supervisor_startup_failed, :global_pause, _}, nil} =
             SupervisedStartup.capture(port, identity(), guard, capture: capture)

    Port.close(port)
  end

  test "unavailable scope reaches a finite deadline" do
    port = open_port("read line")
    capture = fn _, _ -> {:error, {:systemd_unit_not_loaded, "not-found"}} end
    started = System.monotonic_time(:millisecond)

    assert {:error, {:supervisor_startup_failed, :supervisor_startup_timeout, _}, nil} =
             SupervisedStartup.capture(port, identity(), fn -> :ok end, capture: capture, timeout_ms: 75)

    assert System.monotonic_time(:millisecond) - started < 1_000
    Port.close(port)
  end

  test "missing cgroup is terminal and startup output is bounded" do
    port = open_port("read line")
    capture = fn _, _ -> {:error, :supervisor_cgroup_missing} end

    assert {:error, {:supervisor_startup_failed, :supervisor_cgroup_missing, _}, nil} =
             SupervisedStartup.capture(port, identity(), fn -> :ok end, capture: capture)

    for _ <- 1..65, do: send(self(), {port, {:data, {:eol, "x"}}})

    assert {:error, {:supervisor_startup_failed, :supervisor_startup_output_overflow, summary}, nil} =
             SupervisedStartup.capture(port, identity(), fn -> :ok end, capture: fn _, _ -> flunk("capture after overflow") end)

    assert summary.events == 65
    assert length(summary.chunk_sha256) == 64
    Port.close(port)
  end

  test "caller timeout cannot widen the five-second deadline" do
    port = open_port("read line")
    started = System.monotonic_time(:millisecond)

    assert {:error, {:supervisor_startup_failed, :supervisor_startup_timeout, _}, nil} =
             SupervisedStartup.capture(port, identity(), fn -> :ok end,
               timeout_ms: 60_000,
               capture: fn _, _ -> {:error, {:systemd_unit_not_loaded, "not-found"}} end
             )

    assert System.monotonic_time(:millisecond) - started < 7_000
    Port.close(port)
  end

  test "noninteger startup timeout fails before capture" do
    port = open_port("read line")

    assert {:error, {:supervisor_startup_failed, :invalid_supervisor_startup_timeout, _}, nil} =
             SupervisedStartup.capture(port, identity(), fn -> :ok end, timeout_ms: "unbounded")

    Port.close(port)
  end

  test "oversized mailbox fails without copying its messages into diagnostics" do
    port = open_port("read line")
    for _ <- 1..129, do: send(self(), {:unrelated, "private"})

    assert {:error, {:supervisor_startup_failed, :supervisor_startup_mailbox_overflow, summary}, nil} =
             SupervisedStartup.capture(port, identity(), fn -> :ok end)

    assert summary.bytes == nil
    assert summary.chunk_sha256 == []
    assert summary.mailbox_messages >= 129
    Port.close(port)
  end

  test "guard exceptions remain fail closed" do
    port = open_port("read line")

    assert {:error, {:supervisor_startup_failed, :execution_fence_guard_failed, _}, nil} =
             SupervisedStartup.capture(port, identity(), fn -> raise "private" end)

    Port.close(port)
  end

  test "systemctl probe has an enforced subprocess deadline" do
    runner = fn timeout, ["--signal=KILL", duration, "systemctl" | _], opts ->
      System.cmd(timeout, ["--signal=KILL", duration, "sleep", "10"], opts)
    end

    started = System.monotonic_time(:millisecond)

    assert {:error, {:systemd_command_failed, :systemd_command_timeout}} =
             ExecutionSupervisor.capture(identity(), timeout_ms: 50, command_runner: runner)

    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "a pause after capture retains the observed containment identity for cleanup" do
    port = open_port("read line")
    {:ok, checks} = Agent.start_link(fn -> 0 end)

    guard = fn ->
      if Agent.get_and_update(checks, &{&1, &1 + 1}) == 0, do: :ok, else: {:error, :global_pause}
    end

    initial = identity()
    observed = captured(initial)

    assert {:error, {:supervisor_startup_failed, :global_pause, _}, ^observed} =
             SupervisedStartup.capture(port, initial, guard, capture: fn _, _ -> {:ok, observed} end)

    Port.close(port)
  end

  test "captures a real scope immediately and proves all descendants terminated" do
    if match?({:unix, :linux}, :os.type()) and ExecutionSupervisor.available?() == :ok do
      identity = identity()
      {:ok, args} = ExecutionSupervisor.launch_args(identity.unit, System.tmp_dir!(), "sleep 30 & wait")

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(ExecutionSupervisor.executable())},
          [:binary, :exit_status, :stderr_to_stdout, args: Enum.map(args, &String.to_charlist/1), line: 1_048_576]
        )

      try do
        assert {:ok, captured} = SupervisedStartup.capture(port, identity, fn -> :ok end)
        assert captured.launch_processes != []
        assert {:ok, evidence} = ExecutionSupervisor.terminate(captured)
        assert :ok = ExecutionSupervisor.validate_evidence(captured, evidence)
        assert evidence.remaining_processes == 0
      after
        _ = ExecutionSupervisor.terminate(identity)
        if Port.info(port), do: Port.close(port)
      end
    end
  end

  defp identity do
    id = "startup-#{System.unique_integer([:positive])}"
    ExecutionSupervisor.identity(id, 1, "worker-#{id}", "process-#{id}", 0)
  end

  defp captured(identity), do: Map.merge(identity, %{control_group: "/user.slice/test.scope", launch_processes: [1], main_pid: nil})

  defp open_port(command) do
    Port.open(
      {:spawn_executable, String.to_charlist(System.find_executable("bash"))},
      [:binary, :exit_status, :stderr_to_stdout, args: [~c"-c", String.to_charlist(command)], line: 1_048_576]
    )
  end
end
