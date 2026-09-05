defmodule SymphonyElixir.OrchestratorExecutionFenceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ExecutionFence, ExecutionSupervisor, Orchestrator, WorkPackageCleanupReceipt}
  alias SymphonyElixir.ExecutionFence.Persistence
  alias SymphonyElixir.WorkPackageClaim.Journal

  test "an ordinary poll retries a failed cleanup receipt and permits the next generation" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_concurrent_agents: 0
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issues) end)

    issue_id = "HGS-350-retry"
    repository = "openai/symphony"
    profile = "profile-350-retry"
    journal_path = Path.join(System.tmp_dir!(), "symphony-cleanup-retry-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(journal_path) end)

    admission = %{
      issue_id: issue_id,
      repository: repository,
      branch: "codex/hgs-350-retry",
      worktree: Path.join(System.tmp_dir!(), "symphony-hgs-350-retry")
    }

    {:ok, fence_state, token} = ExecutionFence.admit(ExecutionFence.new(), admission, 100)

    session =
      Map.merge(admission, %{
        generation: 1,
        role: :worker,
        session_id: "worker-350-retry",
        process_id: "process-350-retry",
        linear_state: "In Progress",
        pr_state: "OPEN",
        head: "abc123",
        last_heartbeat_at: 100
      })

    {:ok, fence_state, :registered} = ExecutionFence.register(fence_state, token, :worker, session, 100)
    {:ok, fence_state, :released} = ExecutionFence.release(fence_state, token, session.session_id, :orchestrator_stop)

    evidence = %{
      session_id: session.session_id,
      process_id: session.process_id,
      process_tree: :terminated,
      evidence_ref: "process-tree-check-350-retry",
      observed_at_ms: 110
    }

    {:ok, fence_state, :confirmed} =
      ExecutionFence.confirm_termination(fence_state, token, session.session_id, evidence, 110)

    {:ok, fence_state, :fenced} =
      ExecutionFence.fence(fence_state, token, %{terminal_state: "Done", accepted_head: "abc123"}, 120)

    {:ok, fence_state, :prepared} = ExecutionFence.prepare_cleanup(fence_state, token, "abc123", 121)

    {:ok, fence_state} =
      ExecutionFence.record_cleanup_evidence(fence_state, token, "abc123", "sha256:cleanup-350-retry", 122)

    {:ok, fence_state, :cleaned} = ExecutionFence.cleanup(fence_state, token, "abc123", 123)

    reservation_key = Journal.reservation_key(issue_id, profile, repository, 1)

    reservation = %{
      issue_id: issue_id,
      managed_project_profile_id: profile,
      repository_ref: repository,
      projection_id: "projection-350-retry",
      reservation_id: "reservation-350-retry",
      reservation_nonce: "nonce-350-retry",
      scope_keys: ["repo:#{repository}", "work:350-retry"],
      runner_id: "runner-350-retry",
      generation: 1,
      session_id: session.session_id,
      process_id: session.process_id,
      responsible_delegation_id: "delegation-350-retry",
      execution_fence_token: "#{issue_id}:1",
      runtime_lease_id: session.session_id
    }

    {:ok, journal} = Journal.put(Journal.new(), reservation_key, reservation)
    assert :ok = Journal.save(journal_path, journal)

    input = %{
      base_url: "http://provider.test",
      runner_token: "runner-token",
      attestation_key: "attestation-key",
      runner_id: reservation.runner_id,
      managed_project_profile_id: profile,
      issue_id: issue_id,
      repository_ref: repository,
      fence_state: fence_state,
      journal_path: journal_path
    }

    termination_request = fn _url, options ->
      payload = Keyword.fetch!(options, :json)

      {:ok,
       provider_response(%{
         "projectionId" => reservation.projection_id,
         "reservationId" => reservation.reservation_id,
         "receiptId" => payload["receiptId"],
         "receiptKind" => "termination_confirmed",
         "executionCapacityState" => "released",
         "scopeState" => "held",
         "reservationState" => "claimed",
         "generation" => 1,
         "evidenceRef" => payload["evidenceRef"],
         "acceptedHead" => payload["acceptedHead"],
         "replayed" => false
       })}
    end

    assert {:ok, _termination_result} =
             WorkPackageCleanupReceipt.termination_confirmed(
               input,
               %{terminal_outcome: :completed, accepted_head: "abc123"},
               request_fun: termination_request,
               now_fun: fn -> ~U[2026-09-06 10:00:00.000Z] end
             )

    Process.put(:repository_receipt_attempts, 0)

    repository_request = fn _url, options ->
      attempt = Process.get(:repository_receipt_attempts) + 1
      Process.put(:repository_receipt_attempts, attempt)

      if attempt == 1 do
        {:error, :provider_temporarily_unavailable}
      else
        payload = Keyword.fetch!(options, :json)

        {:ok,
         provider_response(%{
           "projectionId" => reservation.projection_id,
           "reservationId" => reservation.reservation_id,
           "receiptId" => payload["receiptId"],
           "receiptKind" => "repository_cleanup_verified",
           "executionCapacityState" => "released",
           "scopeState" => "released",
           "reservationState" => "released",
           "generation" => 1,
           "evidenceRef" => payload["evidenceRef"],
           "acceptedHead" => payload["acceptedHead"],
           "replayed" => false
         })}
      end
    end

    runtime = %{
      base_url: input.base_url,
      runner_token: input.runner_token,
      attestation_key: input.attestation_key,
      runner_id: input.runner_id,
      managed_project_profile_id: input.managed_project_profile_id,
      journal_path: journal_path,
      request_fun: repository_request,
      now_fun: fn -> ~U[2026-09-06 10:01:00.000Z] end,
      cleanup_evidence_fun: fn _state, _token, _head -> {:ok, "sha256:cleanup-350-retry"} end
    }

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 0,
      execution_fence: fence_state,
      work_package_runtime: runtime,
      running: %{},
      blocked: %{},
      claimed: MapSet.new()
    }

    assert {:noreply, after_failed_poll} = Orchestrator.handle_info(:run_poll_cycle, state)
    assert Process.get(:repository_receipt_attempts) == 1
    assert {:ok, journal_after_failure} = Journal.load(journal_path)
    assert :missing = Journal.cleanup_receipt_ack(journal_after_failure, reservation_key, "repository_cleanup_verified")

    assert {:noreply, after_successful_poll} = Orchestrator.handle_info(:run_poll_cycle, after_failed_poll)
    assert Process.get(:repository_receipt_attempts) == 2
    assert {:ok, journal_after_success} = Journal.load(journal_path)

    assert {:ok, acknowledgement} =
             Journal.cleanup_receipt_ack(
               journal_after_success,
               reservation_key,
               "repository_cleanup_verified"
             )

    assert acknowledgement.scope_state == "released"
    assert acknowledgement.reservation_state == "released"
    assert {:ok, _next_fence, next_token} = ExecutionFence.admit(after_successful_poll.execution_fence, admission, 130)
    assert next_token.generation == 2
  end

  test "restart reconciliation stops and confirms persisted supervisor ownership" do
    admission = admission()
    {:ok, fence_state, token} = ExecutionFence.admit(ExecutionFence.new(), admission, 100)
    {:ok, fence_state, :registered} = ExecutionFence.register(fence_state, token, :worker, session(), 100)

    identity =
      ExecutionSupervisor.identity("HGS-294", 1, "worker-1", "logical-process-1", 100)
      |> Map.merge(%{control_group: "/user.slice/symphony.scope", launch_processes: [111], main_pid: 111})

    {:ok, fence_state} = ExecutionFence.record_supervisor(fence_state, token, "worker-1", identity)

    runner = fn _executable, args, _opts ->
      case args do
        ["--user", "show", "--property=LoadState,ActiveState,ControlGroup,MainPID", _unit] ->
          {"LoadState=loaded\nActiveState=active\nControlGroup=/user.slice/symphony.scope\nMainPID=111\n", 0}

        ["--user", "stop", _unit] ->
          {"", 0}

        ["--user", "show", "--property=ActiveState", _unit] ->
          {"ActiveState=inactive\n", 0}

        ["--user", "show", "--property=ControlGroup", _unit] ->
          {"ControlGroup=/user.slice/symphony.scope\n", 0}
      end
    end

    cgroup_reader = fn _path ->
      case Process.get(:restart_cgroup_reads, 0) do
        0 ->
          Process.put(:restart_cgroup_reads, 1)
          {:ok, [111]}

        _ ->
          {:ok, []}
      end
    end

    {:ok, reconciled} =
      Orchestrator.reconcile_persisted_supervisors_for_test(
        fence_state,
        command_runner: runner,
        cgroup_reader: cgroup_reader,
        now_ms: 200
      )

    lease = reconciled.executions["HGS-294"].leases["worker-1"]
    assert lease.status == :released
    assert lease.termination_confirmed_at_ms == 200
    assert reconciled.executions["HGS-294"].termination_unconfirmed == false
    assert reconciled.executions["HGS-294"].ownership == :reconciled
    assert {:ok, _next_state, next_token} = ExecutionFence.admit(reconciled, admission, 210)
    assert next_token.generation == 2
  end

  test "orchestrator mutation guard follows the current generation snapshot" do
    admission = %{
      issue_id: "HGS-294",
      repository: "openai/symphony",
      branch: "codex/hgs-294",
      worktree: "C:/code/hypergrid.au/_worktrees/symphony-hgs-294"
    }

    {:ok, fence_state, token} = ExecutionFence.admit(ExecutionFence.new(), admission, 100)
    state = %Orchestrator.State{execution_fence: fence_state}

    assert {:reply, {:ok, %{generation: 1, action: :state_mutation}}, ^state} =
             Orchestrator.handle_call(
               {:execution_fence_authorize, token, :state_mutation},
               {self(), make_ref()},
               state
             )

    {:ok, fenced_fence, :fenced} =
      ExecutionFence.fence(fence_state, token, %{terminal_state: "Done", accepted_head: "abc123"}, 110)

    fenced_state = %{state | execution_fence: fenced_fence}

    assert {:reply, {:error, :terminal_fenced}, ^fenced_state} =
             Orchestrator.handle_call(
               {:execution_fence_authorize, token, :state_mutation},
               {self(), make_ref()},
               fenced_state
             )
  end

  test "snapshot exposes sanitized execution and session ownership" do
    admission = admission()
    {:ok, fence_state, token} = ExecutionFence.admit(ExecutionFence.new(), admission, 100)
    {:ok, fence_state, :registered} = ExecutionFence.register(fence_state, token, :worker, session(), 100)

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: 100,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      execution_fence: fence_state
    }

    assert {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    assert %{schema_version: 1, executions: [execution], sessions: [session], history: []} = snapshot.execution_fence
    assert execution.issue_id == "HGS-294"
    assert execution.status == :active
    assert execution.cleanup == :pending
    assert session.role == :worker
    assert session.session_id == "worker-1"
    assert session.process_id == "logical-process-1"
    refute Map.has_key?(session, :pid)
    refute Map.has_key?(session, :closure)
  end

  test "matching worker runtime information persists its exact head" do
    admission = admission()
    {:ok, fence_state, token} = ExecutionFence.admit(ExecutionFence.new(), admission, 100)
    {:ok, fence_state, :registered} = ExecutionFence.register(fence_state, token, :worker, session(), 100)

    entry = %{
      execution_token: token,
      execution_session_id: "worker-1",
      worker_host: nil,
      workspace_path: admission.worktree,
      accepted_head: nil
    }

    state = %Orchestrator.State{
      execution_fence: fence_state,
      running: %{"HGS-294" => entry}
    }

    runtime_info = %{
      execution_token: token,
      execution_session_id: "worker-1",
      worker_host: nil,
      workspace_path: admission.worktree,
      head: "def456"
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_info(
               {:worker_runtime_info, "HGS-294", runtime_info},
               state
             )

    assert updated_state.running["HGS-294"].accepted_head == "def456"
    assert updated_state.execution_fence.sessions["worker-1"].head == "def456"
  end

  test "runtime information from another generation is ignored" do
    admission = admission()
    {:ok, fence_state, token} = ExecutionFence.admit(ExecutionFence.new(), admission, 100)
    {:ok, fence_state, :registered} = ExecutionFence.register(fence_state, token, :worker, session(), 100)

    entry = %{execution_token: token, execution_session_id: "worker-1", accepted_head: nil}
    state = %Orchestrator.State{execution_fence: fence_state, running: %{"HGS-294" => entry}}

    stale_info = %{
      execution_token: %{issue_id: "HGS-294", generation: 99},
      execution_session_id: "worker-1",
      head: "def456"
    }

    assert {:noreply, ^state} =
             Orchestrator.handle_info({:worker_runtime_info, "HGS-294", stale_info}, state)
  end

  test "orchestrator persists one head-divergence triage record" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestrator-triage-#{System.unique_integer([:positive])}"
      )

    path = Path.join(root, "execution-fence.json")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, fence_state, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)
    {:ok, fence_state, :fenced} = ExecutionFence.fence(fence_state, token, %{terminal_state: "Done", accepted_head: "abc123"}, 110)
    state = %Orchestrator.State{execution_fence: fence_state, execution_fence_path: path}

    assert {:reply, {:ok, :recorded}, updated_state} =
             Orchestrator.handle_call(
               {:execution_fence_head_divergence, token, "abc123", "def456", 120},
               {self(), make_ref()},
               state
             )

    assert {:ok, persisted} = Persistence.load(path)
    assert [%{observed_head: "def456"}] = Map.values(persisted.triage_records)

    assert {:reply, {:ok, :already_recorded}, ^updated_state} =
             Orchestrator.handle_call(
               {:execution_fence_head_divergence, token, "abc123", "ghi789", 121},
               {self(), make_ref()},
               updated_state
             )
  end

  test "terminal reconciliation preserves a divergent workspace and persists triage" do
    workflow_root = Path.dirname(Workflow.workflow_file_path())
    workspace_root = Path.join(workflow_root, "workspace-root")
    workspace = Path.join(workspace_root, "workspace")
    state_path = Path.join(workflow_root, "execution-fence.json")
    issue_id = "HGS-294-divergence"
    issue_identifier = "MT-294-divergence"

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "workspace-root",
      tracker_active_states: ["Todo"],
      tracker_terminal_states: ["Done"]
    )

    {_, 0} = System.cmd("git", ["init", "-q"], cd: workspace)
    File.write!(Path.join(workspace, "README.md"), "initial\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: workspace)

    {_, 0} =
      System.cmd(
        "git",
        ["-c", "user.name=Symphony Test", "-c", "user.email=symphony@example.test", "commit", "-qm", "initial"],
        cd: workspace
      )

    {old_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
    old_head = String.trim(old_head)

    File.write!(Path.join(workspace, "README.md"), "diverged\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: workspace)

    {_, 0} =
      System.cmd(
        "git",
        ["-c", "user.name=Symphony Test", "-c", "user.email=symphony@example.test", "commit", "-qm", "diverged"],
        cd: workspace
      )

    {observed_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
    observed_head = String.trim(observed_head)
    assert {:ok, ^observed_head} = Workspace.current_head(workspace)

    execution_attrs =
      admission()
      |> Map.put(:issue_id, issue_id)
      |> Map.put(:worktree, workspace)

    {:ok, fence_state, token} = ExecutionFence.admit(ExecutionFence.new(), execution_attrs, 100)

    {:ok, fence_state, :registered} =
      ExecutionFence.register(
        fence_state,
        token,
        :worker,
        session()
        |> Map.put(:issue_id, issue_id)
        |> Map.put(:worktree, workspace),
        100
      )

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      task_supervisor: SymphonyElixir.TaskSupervisor,
      execution_fence: fence_state,
      execution_fence_path: state_path,
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: issue_identifier,
          issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
          execution_token: token,
          execution_session_id: "worker-1",
          workspace_path: workspace,
          accepted_head: old_head,
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    terminal_issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      state: "Done",
      title: "Diverged",
      description: "Unexpected post-terminal delta",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([terminal_issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    assert File.dir?(workspace)
    assert updated_state.execution_fence.executions[issue_id].cleanup == :pending
    assert [%{expected_head: ^old_head, observed_head: ^observed_head}] = Map.values(updated_state.execution_fence.triage_records)
    assert {:ok, persisted} = Persistence.load(state_path)
    assert persisted.triage_records == updated_state.execution_fence.triage_records
    assert persisted.executions[issue_id].cleanup == :pending
    assert length(Map.values(persisted.triage_records)) == 1
  end

  test "reconciliation call applies blocked ownership and returns its evidence" do
    admission = admission()
    {:ok, fence_state, token} = ExecutionFence.admit(ExecutionFence.new(), admission, 100)
    {:ok, fence_state, :registered} = ExecutionFence.register(fence_state, token, :worker, session(), 100)
    state = %Orchestrator.State{execution_fence: fence_state}
    unknown = Map.put(session(), :session_id, "unknown-session")

    assert {:reply, {:ok, %{summary: %{status: :blocked, unknown: unknown_ids}, execution_fence: _}}, updated_state} =
             Orchestrator.handle_call(
               {:execution_fence_reconcile, [unknown], 101, 50},
               {self(), make_ref()},
               state
             )

    assert unknown_ids == ["unknown-session", "worker-1"]
    assert updated_state.execution_fence.executions["HGS-294"].ownership == :unknown
  end

  defp admission do
    %{
      issue_id: "HGS-294",
      repository: "openai/symphony",
      branch: "codex/hgs-294",
      worktree: "C:/code/hypergrid.au/_worktrees/symphony-hgs-294"
    }
  end

  defp session do
    Map.merge(admission(), %{
      generation: 1,
      role: :worker,
      session_id: "worker-1",
      process_id: "logical-process-1",
      linear_state: "In Progress",
      pr_state: "OPEN",
      head: "abc123",
      last_heartbeat_at: 100
    })
  end

  defp provider_response(data), do: %Req.Response{status: 200, body: %{"data" => data}}
end
