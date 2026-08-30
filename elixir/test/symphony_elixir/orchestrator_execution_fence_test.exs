defmodule SymphonyElixir.OrchestratorExecutionFenceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ExecutionFence, Orchestrator}

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
