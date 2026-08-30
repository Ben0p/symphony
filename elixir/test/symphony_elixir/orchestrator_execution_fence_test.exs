defmodule SymphonyElixir.OrchestratorExecutionFenceTest do
  use ExUnit.Case, async: true

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
end
