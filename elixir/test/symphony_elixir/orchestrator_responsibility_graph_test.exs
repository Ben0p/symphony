defmodule SymphonyElixir.OrchestratorResponsibilityGraphTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{ExecutionFence, Orchestrator, ResponsibilityGraph}

  test "orchestrator callback persists, authorizes, and revokes a delegation" do
    {fence, token} = active_fence()

    state = %Orchestrator.State{
      execution_fence: fence,
      responsibility_graph: ResponsibilityGraph.new(),
      responsibility_graph_path: nil
    }

    {:reply, {:ok, _owner}, state1} =
      Orchestrator.handle_call(
        {:responsibility_delegate, delegation("owner", :accountable), 0},
        self(),
        state
      )

    {:reply, {:ok, _worker}, state2} =
      Orchestrator.handle_call(
        {:responsibility_delegate, delegation("worker", :responsible, parent_delegation_id: "owner", runtime_lease: runtime_lease()), 1},
        self(),
        state1
      )

    {:reply, {:ok, authorization}, state3} =
      Orchestrator.handle_call({:responsibility_authorize, "worker", :commit}, self(), state2)

    assert authorization.execution_fence.generation == token.generation

    terminal = %{terminal_state: "done", accepted_head: "abc123", merge_identity: "merge-1"}

    {:reply, {:ok, %{delegation_ids: ["worker"]}}, state4} =
      Orchestrator.handle_call(
        {:responsibility_revoke, "worker", :terminal, terminal, 2},
        self(),
        state3
      )

    assert state4.responsibility_graph.delegations["worker"].status == :revoked
    assert state4.execution_fence.executions["HGS-300"].status == :terminal
  end

  defp delegation(id, role, overrides \\ []) do
    Map.merge(
      %{
        id: id,
        parent_delegation_id: nil,
        role: role,
        actor_id: "actor-#{id}",
        scope: scope(),
        authority: authority(),
        budget: %{model: "luna", effort: :max, max_tokens: 10_000, max_children: 4},
        runtime_lease: nil,
        expires_at_ms: 10_000,
        expected_deliverable: "bounded deliverable",
        expected_evidence: "tests and review evidence",
        return_to_parent: %{owner_id: "owner", contract: "return evidence and outcome"}
      },
      Map.new(overrides)
    )
  end

  defp scope do
    %{
      company_id: "hypergrid",
      objective_id: "objective-1",
      initiative_id: "initiative-1",
      project_id: "project-1",
      work_package_id: "package-1",
      issue_id: "HGS-300",
      repository: "orchestrator",
      paths: [],
      modules: [],
      environments: ["local"],
      actions: [:read, :observe, :delegate, :reconcile, :edit, :commit, :push, :state_mutation, :cleanup, :review, :report]
    }
  end

  defp authority do
    %{
      class: :routine_engineering,
      capabilities: [:read, :observe, :delegate, :reconcile, :edit, :commit, :push, :state_mutation, :cleanup, :review, :report],
      environments: ["local"]
    }
  end

  defp runtime_lease do
    %{issue_id: "HGS-300", repository: "orchestrator", generation: 1, session_id: "worker", process_id: "process-worker"}
  end

  defp active_fence do
    {:ok, state, token} =
      ExecutionFence.admit(
        ExecutionFence.new(),
        %{issue_id: "HGS-300", repository: "orchestrator", branch: "hgs-300", worktree: "worktree"},
        0
      )

    {:ok, state, :registered} =
      ExecutionFence.register(
        state,
        token,
        :worker,
        %{
          session_id: "worker",
          process_id: "process-worker",
          branch: "hgs-300",
          worktree: "worktree",
          linear_state: "In Progress",
          pr_state: "none",
          head: "abc123",
          last_heartbeat_at: 0
        },
        0
      )

    {state, token}
  end
end
