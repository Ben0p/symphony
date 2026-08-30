defmodule SymphonyElixir.StartupMaintenanceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{StartupMaintenance, Workspace}

  test "cleanup fails closed when active tracker data is incomplete" do
    parent = self()

    fetcher = fn
      ["Todo", "In Progress"] -> {:error, :timeout}
      ["Done"] -> {:ok, [issue("done-1", "HGS-1", "Done")]}
    end

    cleaner = fn _issue ->
      send(parent, :cleaned)
      :ok
    end

    assert {:ok, result} =
             StartupMaintenance.run(fetcher, cleaner, %{
               active_states: ["Todo", "In Progress"],
               terminal_states: ["Done"]
             })

    assert result.status == "failed"
    assert result.cleaned_count == 0
    assert result.failure_count == 1
    assert result.error_summary =~ "tracker fetch failed"
    refute_receive :cleaned
  end

  test "cleanup skips terminal issues that still have an active workspace identity" do
    parent = self()

    active_issue = issue("active-id", "HGS-2", "In Progress")
    skipped_terminal = issue("terminal-id", "HGS-2", "Done")
    cleaned_terminal = issue("terminal-clean", "HGS-3", "Done")

    fetcher = fn
      ["In Progress"] -> {:ok, [active_issue]}
      ["Done"] -> {:ok, [skipped_terminal, cleaned_terminal]}
    end

    cleaner = fn issue ->
      send(parent, {:cleaned, issue.identifier})
      :ok
    end

    assert {:ok, result} =
             StartupMaintenance.run(fetcher, cleaner, %{
               active_states: ["In Progress"],
               terminal_states: ["Done"]
             })

    assert result.status == "succeeded"
    assert result.cleaned_count == 1
    assert result.skipped_active_count == 1
    assert result.failure_count == 0
    assert_receive {:cleaned, "HGS-3"}
    refute_receive {:cleaned, "HGS-2"}
  end

  test "cleanup failures are summarized without leaking token-shaped values" do
    fetcher = fn
      ["In Progress"] -> {:ok, []}
      ["Done"] -> {:ok, [issue("done-secret", "HGS-4", "Done")]}
    end

    cleaner = fn _issue ->
      {:error, {:linear_api_request, "lin_api_should_not_escape"}}
    end

    assert {:ok, result} =
             StartupMaintenance.run(fetcher, cleaner, %{
               active_states: ["In Progress"],
               terminal_states: ["Done"]
             })

    assert result.status == "failed"
    assert result.failure_count == 1
    [failure] = result.failures
    assert failure.issue_identifier == "HGS-4"
    refute failure.error_summary =~ "lin_api_should_not_escape"
    assert failure.error_summary =~ "[redacted]"
  end

  test "snapshot exposes maintenance state without process internals" do
    ref = make_ref()

    snapshot =
      StartupMaintenance.start()
      |> Map.put(:task_ref, ref)
      |> Map.put(:task_pid, self())
      |> StartupMaintenance.snapshot()

    assert snapshot.status == "running"
    assert snapshot.timeout_ms == StartupMaintenance.timeout_ms()
    refute Map.has_key?(snapshot, :task_ref)
    refute Map.has_key?(snapshot, :task_pid)
    refute Map.has_key?(snapshot, :started_monotonic_ms)
  end

  test "timeout and restart metadata remain observable" do
    timed_out = StartupMaintenance.start() |> StartupMaintenance.timeout()
    restarted = StartupMaintenance.start()

    assert timed_out.status == "timed_out"
    assert timed_out.failure_count == 1
    assert restarted.status == "running"
    assert restarted.timeout_ms == StartupMaintenance.timeout_ms()
  end

  test "successful completion records the last success without task internals" do
    completed =
      StartupMaintenance.start()
      |> Map.put(:task_ref, make_ref())
      |> Map.put(:task_pid, self())
      |> StartupMaintenance.complete(%{
        status: "succeeded",
        cleaned_count: 1,
        skipped_active_count: 0,
        failure_count: 0,
        duration_ms: 5
      })

    assert completed.status == "succeeded"
    assert completed.cleaned_count == 1
    assert %DateTime{} = completed.last_success_at
    refute Map.has_key?(completed, :task_ref)
    refute Map.has_key?(completed, :task_pid)
  end

  test "startup workspace cleanup runs outside the BEAM and preserves adjacent workspaces" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-startup cleanup & guard (#{System.unique_integer([:positive])})"
      )
      |> String.replace("\\", "/")

    target = Path.join(workspace_root, "HGS-DELETE")
    adjacent = Path.join(workspace_root, "HGS-KEEP")

    try do
      write_workflow_file!(Application.get_env(:symphony_elixir, :workflow_file_path),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      for index <- 1..250 do
        path = Path.join([target, "nested", Integer.to_string(rem(index, 10)), "#{index}.txt"])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "cleanup")
      end

      File.mkdir_p!(adjacent)
      File.write!(Path.join(adjacent, "keep.txt"), "keep")

      assert :ok = Workspace.remove_issue_workspaces_for_startup("HGS-DELETE")
      refute File.exists?(target)
      assert File.read!(Path.join(adjacent, "keep.txt")) == "keep"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "orchestrator initialization is prompt and dispatch waits for startup maintenance" do
    write_workflow_file!(Application.get_env(:symphony_elixir, :workflow_file_path),
      tracker_kind: "memory"
    )

    parent = self()

    maintenance_fun = fn ->
      send(parent, {:maintenance_started, self()})

      receive do
        :finish_maintenance ->
          {:ok,
           %{
             status: "succeeded",
             cleaned_count: 0,
             skipped_active_count: 0,
             failure_count: 0,
             duration_ms: 10
           }}
      end
    end

    orchestrator_name = Module.concat(__MODULE__, PromptStartupOrchestrator)
    started_ms = System.monotonic_time(:millisecond)

    {:ok, orchestrator} =
      Orchestrator.start_link(
        name: orchestrator_name,
        startup_maintenance_fun: maintenance_fun
      )

    assert System.monotonic_time(:millisecond) - started_ms < 500
    assert_receive {:maintenance_started, maintenance_pid}, 500

    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert snapshot.startup_maintenance.status == "running"
    assert snapshot.polling.checking? == false
    assert snapshot.polling.next_poll_in_ms == nil

    send(maintenance_pid, :finish_maintenance)
    Process.sleep(50)

    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert snapshot.startup_maintenance.status == "succeeded"
    assert %DateTime{} = snapshot.startup_maintenance.last_success_at

    GenServer.stop(orchestrator)
  end

  defp issue(id, identifier, state) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Startup maintenance #{identifier}",
      state: state
    }
  end
end
