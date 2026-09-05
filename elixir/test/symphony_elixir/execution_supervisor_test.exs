defmodule SymphonyElixir.ExecutionSupervisorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionSupervisor
  alias SymphonyElixir.ExecutionFence
  alias SymphonyElixir.ExecutionFence.Persistence

  test "launches each generation in an isolated systemd user scope" do
    identity = ExecutionSupervisor.identity("issue-350", 4, "worker-350", "port-350", 100)
    assert identity.supervisor == :systemd_user
    assert String.starts_with?(identity.unit, "symphony-exec-")

    assert {:ok, args} =
             ExecutionSupervisor.launch_args(
               identity.unit,
               "/srv/symphony/workspaces/issue-350",
               "exec codex app-server"
             )

    assert args == [
             "--user",
             "--scope",
             "--quiet",
             "--unit=#{identity.unit}",
             "--property=KillMode=control-group",
             "--working-directory=/srv/symphony/workspaces/issue-350",
             "--",
             "bash",
             "-lc",
             "exec codex app-server"
           ]
  end

  test "rejects shell and unit injection before creating a scope" do
    assert {:error, :invalid_supervisor_unit} =
             ExecutionSupervisor.launch_args("symphony-exec-abc.scope;rm", "/tmp/work", "echo ok")

    assert {:error, :invalid_supervisor_cwd} =
             ExecutionSupervisor.launch_args("symphony-exec-abc.scope", "", "echo ok")

    assert {:error, :invalid_supervisor_command} =
             ExecutionSupervisor.launch_args("symphony-exec-abc.scope", "/tmp/work", "echo ok\nrm -rf /")
  end

  test "stops a unit and requires an inactive systemd boundary" do
    identity = ExecutionSupervisor.identity("issue-350", 4, "worker-350", "port-350", 100)
    parent = self()
    {:ok, cgroup_reads} = Agent.start_link(fn -> 0 end)

    runner = fn executable, args, _opts ->
      send(parent, {:command, executable, args})

      case args do
        ["--user", "stop", "--wait", _unit] ->
          {"", 0}

        ["--user", "show", "--property=LoadState,ActiveState,ControlGroup,MainPID", "--value", _unit] ->
          {"loaded\nactive\n/user.slice/symphony.scope\n111\n", 0}

        ["--user", "show", "--property=ActiveState", "--value", _unit] ->
          {"inactive\n", 0}

        ["--user", "show", "--property=ControlGroup", "--value", _unit] ->
          {"/user.slice/symphony.scope\n", 0}
      end
    end

    cgroup_reader = fn _path ->
      Agent.get_and_update(cgroup_reads, fn count ->
        if count == 0, do: {{:ok, [111, 222]}, 1}, else: {{:ok, []}, count + 1}
      end)
    end

    assert {:ok, evidence} =
             ExecutionSupervisor.terminate(
               identity,
               command_runner: runner,
               cgroup_reader: cgroup_reader,
               now_ms: 200
             )

    assert evidence.process_tree == :terminated
    assert evidence.supervisor == :systemd_user
    assert evidence.unit == identity.unit
    assert evidence.control_group == "/user.slice/symphony.scope"
    assert evidence.pre_processes == [111, 222]
    assert evidence.main_pid == 111
    assert evidence.observed_at_ms == 200
    assert :ok = ExecutionSupervisor.validate_evidence(identity, evidence)
    assert_received {:command, "systemctl", ["--user", "stop", "--wait", _]}
  end

  test "leaves termination unconfirmed while the unit remains active" do
    identity = ExecutionSupervisor.identity("issue-350", 4, "worker-350", "port-350", 100)

    runner = fn _executable, args, _opts ->
      case args do
        ["--user", "stop", "--wait", _unit] ->
          {"", 0}

        ["--user", "show", "--property=LoadState,ActiveState,ControlGroup,MainPID", "--value", _unit] ->
          {"loaded\nactive\n/user.slice/symphony.scope\n111\n", 0}

        ["--user", "show", "--property=ActiveState", "--value", _unit] ->
          {"active\n", 0}
      end
    end

    assert {:error, :systemd_unit_still_active} =
             ExecutionSupervisor.terminate(identity, command_runner: runner, cgroup_reader: fn _ -> {:ok, [111]} end, now_ms: 200)
  end

  test "reconciles a retained scope that disappeared with the user manager" do
    identity = ExecutionSupervisor.identity("issue-350", 4, "worker-350", "port-350", 100)

    runner = fn _executable, args, _opts ->
      case args do
        ["--user", "stop", "--wait", _unit] -> {"not-found\n", 5}
        ["--user", "show", "--property=LoadState,ActiveState,ControlGroup,MainPID", "--value", _unit] -> {"not-found\ninactive\n\n0\n", 0}
      end
    end

    assert {:ok, evidence} =
             ExecutionSupervisor.terminate(identity, command_runner: runner, now_ms: 200)

    assert evidence.process_tree == :terminated
    assert evidence.active_state == "inactive"
    assert evidence.control_group == nil
    assert :ok = ExecutionSupervisor.validate_evidence(identity, evidence)
  end

  test "does not treat a failed or deactivating scope as terminated" do
    identity = ExecutionSupervisor.identity("issue-350", 4, "worker-350", "port-350", 100)

    for active_state <- ["failed", "deactivating"] do
      runner = fn _executable, args, _opts ->
        case args do
          ["--user", "stop", "--wait", _unit] ->
            {"", 0}

          ["--user", "show", "--property=LoadState,ActiveState,ControlGroup,MainPID", "--value", _unit] ->
            {"loaded\n#{active_state}\n/user.slice/symphony.scope\n111\n", 0}

          ["--user", "show", "--property=ActiveState", "--value", _unit] ->
            {active_state <> "\n", 0}
        end
      end

      assert {:error, _reason} =
               ExecutionSupervisor.terminate(identity, command_runner: runner, cgroup_reader: fn _ -> {:ok, [111]} end, now_ms: 200)
    end
  end

  test "persists the supervisor identity and only accepts matching restart proof" do
    path = Path.join(System.tmp_dir!(), "symphony-supervisor-fence-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    admission = %{issue_id: "issue-350", repository: "hypergridau/symphony", branch: "codex/350", worktree: "/tmp/350"}
    {:ok, state, token} = ExecutionFence.admit(ExecutionFence.new(), admission, 0)

    lease_attrs = %{
      session_id: "worker-350",
      process_id: "process-350",
      branch: admission.branch,
      worktree: admission.worktree,
      linear_state: "In Progress",
      pr_state: "OPEN",
      head: "abc123",
      last_heartbeat_at: 0
    }

    {:ok, state, :registered} = ExecutionFence.register(state, token, :worker, lease_attrs, 0)
    identity = ExecutionSupervisor.identity("issue-350", 1, "worker-350", "process-350", 1)
    assert {:ok, state} = ExecutionFence.record_supervisor(state, token, "worker-350", identity)
    assert :ok = Persistence.save(path, state)
    assert {:ok, state} = Persistence.load(path)
    assert get_in(state, [:executions, "issue-350", :leases, "worker-350", :supervisor_identity]) == identity

    {:ok, state, :released} = ExecutionFence.release(state, token, "worker-350", :orchestrator_stop)

    bad_evidence = %{
      session_id: "worker-350",
      process_id: "process-350",
      process_tree: :terminated,
      supervisor: :systemd_user,
      unit: "symphony-exec-wrong",
      active_state: "inactive",
      remaining_processes: 0,
      evidence_ref: "wrong",
      observed_at_ms: 2
    }

    assert {:error, :termination_supervisor_mismatch} =
             ExecutionFence.confirm_termination(state, token, "worker-350", bad_evidence, 2)

    evidence = %{
      session_id: "worker-350",
      process_id: "process-350",
      process_tree: :terminated,
      supervisor: :systemd_user,
      unit: identity.unit,
      active_state: "inactive",
      remaining_processes: 0,
      evidence_ref: "systemd:proof-350",
      observed_at_ms: 2
    }

    assert {:ok, state, :confirmed} =
             ExecutionFence.confirm_termination(state, token, "worker-350", evidence, 2)

    assert get_in(state, [:executions, "issue-350", :termination_unconfirmed]) == false
  end

  test "contains and terminates a real descendant on admitted Linux workers" do
    if match?({:unix, :linux}, :os.type()) and is_binary(ExecutionSupervisor.executable()) do
      case ExecutionSupervisor.available?() do
        :ok ->
          cwd = Path.join(System.tmp_dir!(), "symphony-supervisor-live-#{System.unique_integer([:positive])}")
          File.mkdir_p!(cwd)
          identity = ExecutionSupervisor.identity("issue-live-350", 1, "worker-live-350", "process-live-350", 0)
          {:ok, args} = ExecutionSupervisor.launch_args(identity.unit, cwd, "sleep 30 & wait")

          port =
            Port.open(
              {:spawn_executable, String.to_charlist(ExecutionSupervisor.executable())},
              [:binary, :exit_status, :stderr_to_stdout, args: Enum.map(args, &String.to_charlist/1)]
            )

          on_exit(fn ->
            _ = ExecutionSupervisor.terminate(identity)
            if Port.info(port), do: Port.close(port)
            File.rm_rf(cwd)
          end)

          Process.sleep(500)
          assert {:ok, evidence} = ExecutionSupervisor.terminate(identity, now_ms: 500)
          assert evidence.process_tree == :terminated
          assert :ok = ExecutionSupervisor.validate_evidence(identity, evidence)

        {:error, _reason} ->
          :ok
      end
    else
      :ok
    end
  end
end
