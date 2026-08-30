defmodule SymphonyElixir.OrchestratorExecutionFenceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ExecutionFence, Orchestrator}
  alias SymphonyElixir.ExecutionFence.Persistence

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
end
