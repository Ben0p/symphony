defmodule SymphonyElixir.ResponsibilityGraphTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{ExecutionFence, ResponsibilityGraph}

  @scope %{
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

  @authority %{
    class: :routine_engineering,
    capabilities: [:read, :observe, :delegate, :reconcile, :edit, :commit, :push, :state_mutation, :cleanup, :review, :report],
    environments: ["local"]
  }

  @budget %{model: "luna", effort: :max, max_tokens: 10_000, max_children: 4}

  test "enforces one accountable owner and inherited child scope" do
    {:ok, graph, _owner} = ResponsibilityGraph.delegate(ResponsibilityGraph.new(), delegation("owner", :accountable), 0)

    assert {:error, :accountable_owner_exists} =
             ResponsibilityGraph.delegate(graph, delegation("owner-2", :accountable), 1)

    child = delegation("worker", :responsible, parent_delegation_id: "owner", runtime_lease: runtime_lease())
    assert {:ok, graph2, _worker} = ResponsibilityGraph.delegate(graph, child, 2)
    assert :ok = ResponsibilityGraph.validate(graph2)
    assert %{edges: %{"owner" => ["worker"]}} = ResponsibilityGraph.snapshot(graph2)
  end

  test "rejects child scope, authority, and budget widening" do
    {:ok, graph, _owner} =
      ResponsibilityGraph.delegate(
        ResponsibilityGraph.new(),
        delegation("owner", :accountable, scope: put_in(@scope, [:paths], ["elixir"])),
        0
      )

    assert {:error, :scope_widening} =
             ResponsibilityGraph.delegate(
               graph,
               delegation("wide-scope", :responsible,
                 parent_delegation_id: "owner",
                 scope: put_in(@scope, [:paths], ["elixir", "docs"]),
                 runtime_lease: runtime_lease()
               ),
               1
             )

    assert {:error, :authority_widening} =
             ResponsibilityGraph.delegate(
               graph,
               delegation("wide-authority", :responsible,
                 parent_delegation_id: "owner",
                 authority: %{@authority | environments: ["local", "production"]},
                 runtime_lease: runtime_lease()
               ),
               1
             )

    assert {:error, :budget_widening} =
             ResponsibilityGraph.delegate(
               graph,
               delegation("wide-budget", :responsible,
                 parent_delegation_id: "owner",
                 budget: %{@budget | max_tokens: 20_000},
                 runtime_lease: runtime_lease()
               ),
               1
             )
  end

  test "allows disjoint workers but rejects overlapping mutable workers" do
    {:ok, graph, _owner} = ResponsibilityGraph.delegate(ResponsibilityGraph.new(), delegation("owner", :accountable), 0)

    worker = delegation("worker-a", :responsible, parent_delegation_id: "owner", runtime_lease: runtime_lease("worker-a"), scope: put_in(@scope, [:paths], ["elixir"]))
    assert {:ok, graph1, _} = ResponsibilityGraph.delegate(graph, worker, 1)

    assert {:error, {:overlapping_mutable_scope, "worker-a"}} =
             ResponsibilityGraph.delegate(
               graph1,
               delegation("worker-b", :responsible,
                 parent_delegation_id: "owner",
                 runtime_lease: runtime_lease("worker-b"),
                 scope: put_in(@scope, [:paths], ["elixir"])
               ),
               2
             )

    assert {:ok, graph2, _} =
             ResponsibilityGraph.delegate(
               graph1,
               delegation("worker-c", :responsible,
                 parent_delegation_id: "owner",
                 runtime_lease: runtime_lease("worker-c"),
                 scope: put_in(@scope, [:paths], ["docs"])
               ),
               2
             )

    assert :ok = ResponsibilityGraph.validate(graph2)
  end

  test "blocks a parent worker from mutating a child-owned scope" do
    {:ok, graph, _owner} = ResponsibilityGraph.delegate(ResponsibilityGraph.new(), delegation("owner", :accountable), 0)

    parent =
      delegation("manager-worker", :responsible,
        parent_delegation_id: "owner",
        runtime_lease: runtime_lease("manager-worker"),
        scope: put_in(@scope, [:paths], [])
      )

    {:ok, graph1, _} = ResponsibilityGraph.delegate(graph, parent, 1)

    child =
      delegation("child-worker", :responsible,
        parent_delegation_id: "manager-worker",
        runtime_lease: runtime_lease("child-worker"),
        scope: put_in(@scope, [:paths], ["elixir"])
      )

    {:ok, graph2, _} = ResponsibilityGraph.delegate(graph1, child, 2)
    assert {:error, {:child_scope_owned, "child-worker"}} = ResponsibilityGraph.authorize(graph2, "manager-worker", :commit)
  end

  test "keeps reviewers read-only and creates remediation through the manager" do
    {:ok, graph, _owner} = ResponsibilityGraph.delegate(ResponsibilityGraph.new(), delegation("owner", :accountable), 0)

    reviewer = delegation("reviewer", :reviewer, parent_delegation_id: "owner", runtime_lease: runtime_lease("reviewer"))
    {:ok, graph1, _} = ResponsibilityGraph.delegate(graph, reviewer, 1)
    assert {:error, :reviewer_read_only} = ResponsibilityGraph.authorize(graph1, "reviewer", :commit)

    remediation =
      delegation("remediation", :responsible,
        parent_delegation_id: "owner",
        runtime_lease: runtime_lease("remediation"),
        finding: "The exact head was not reconciled"
      )

    assert {:ok, proposal} = ResponsibilityGraph.propose_remediation(graph1, "reviewer", remediation, 2)
    refute Map.has_key?(graph.delegations, "remediation")
    assert {:ok, graph2, _} = ResponsibilityGraph.delegate_remediation(graph1, "reviewer", remediation, 2)
    assert graph2.delegations["remediation"].reviewer_delegation_id == "reviewer"
    assert proposal.role == :responsible
  end

  test "combines graph authority with an active HGS-294 worker lease" do
    {:ok, graph, _owner} = ResponsibilityGraph.delegate(ResponsibilityGraph.new(), delegation("owner", :accountable), 0)
    worker = delegation("worker", :responsible, parent_delegation_id: "owner", runtime_lease: runtime_lease())
    {:ok, graph1, _} = ResponsibilityGraph.delegate(graph, worker, 1)

    {fence, token} = active_fence()

    assert {:ok, authorization} =
             ResponsibilityGraph.authorize_with_execution_fence(graph1, "worker", :commit, fence)

    assert authorization.execution_fence.action == :commit
    assert authorization.runtime_lease.session_id == "worker"

    assert {:error, :unknown_execution} =
             ResponsibilityGraph.authorize_with_execution_fence(graph1, "worker", :commit, ExecutionFence.new())

    assert token == %{issue_id: "HGS-300", generation: 1}
  end

  test "restart blocks delegations and reconciliation restores only the same runtime lease" do
    {:ok, graph, _owner} = ResponsibilityGraph.delegate(ResponsibilityGraph.new(), delegation("owner", :accountable), 0)
    {:ok, graph1, _} = ResponsibilityGraph.delegate(graph, delegation("worker", :responsible, parent_delegation_id: "owner", runtime_lease: runtime_lease()), 1)
    {:ok, blocked} = ResponsibilityGraph.mark_unreconciled_after_restart(graph1)

    assert {:error, {:delegation_not_active, :blocked}} = ResponsibilityGraph.authorize(blocked, "worker", :commit)
    assert {:ok, blocked_owner} = ResponsibilityGraph.reconcile_delegation(blocked, "owner", nil, 2)

    assert {:error, :runtime_scope_mismatch} =
             ResponsibilityGraph.reconcile_delegation(blocked_owner, "worker", %{runtime_lease() | issue_id: "OTHER-1"}, 3)

    assert {:ok, restored} = ResponsibilityGraph.reconcile_delegation(blocked_owner, "worker", runtime_lease(), 3)
    assert {:ok, _} = ResponsibilityGraph.authorize(restored, "worker", :commit)
  end

  test "revocation fences descendants through the HGS-294 generation" do
    {:ok, graph, _owner} = ResponsibilityGraph.delegate(ResponsibilityGraph.new(), delegation("owner", :accountable), 0)
    {:ok, graph1, _} = ResponsibilityGraph.delegate(graph, delegation("worker", :responsible, parent_delegation_id: "owner", runtime_lease: runtime_lease()), 1)
    {fence, _token} = active_fence()

    terminal = %{terminal_state: "done", accepted_head: "abc123", merge_identity: "merge-1"}

    assert {:ok, graph_revoked, fenced, %{delegation_ids: ["worker"], execution_leases: [_]}} =
             ResponsibilityGraph.revoke_and_fence(graph1, fence, "worker", :terminal, terminal, 2)

    assert graph_revoked.delegations["worker"].status == :revoked
    assert fenced.executions["HGS-300"].status == :terminal

    assert {:error, :terminal_fenced} =
             ExecutionFence.authorize(fenced, %{issue_id: "HGS-300", generation: 1}, :commit)
  end

  test "records handoff, failure, and terminal completion as bounded returns" do
    for {operation, expected_status, payload} <- [
          {:handoff, :handed_off, :returned_to_parent},
          {:fail, :failed, :worker_failed},
          {:complete, :completed, %{tests: "passed"}}
        ] do
      {:ok, graph, _owner} = ResponsibilityGraph.delegate(ResponsibilityGraph.new(), delegation("owner", :accountable), 0)

      {:ok, next_graph, %{delegation_ids: ["owner"]}} =
        apply(ResponsibilityGraph, operation, [graph, "owner", payload, 1])

      assert next_graph.delegations["owner"].status == expected_status
      assert {:error, {:delegation_not_active, ^expected_status}} = ResponsibilityGraph.authorize(next_graph, "owner", :report)
    end
  end

  defp delegation(id, role, overrides \\ []) do
    Map.merge(
      %{
        id: id,
        parent_delegation_id: nil,
        role: role,
        actor_id: "actor-#{id}",
        scope: @scope,
        authority: @authority,
        budget: @budget,
        runtime_lease: nil,
        expires_at_ms: 10_000,
        expected_deliverable: "bounded deliverable",
        expected_evidence: "tests and review evidence",
        return_to_parent: %{owner_id: "owner", contract: "return evidence and outcome"}
      },
      Map.new(overrides)
    )
  end

  defp runtime_lease(session_id \\ "worker") do
    %{issue_id: "HGS-300", repository: "orchestrator", generation: 1, session_id: session_id, process_id: "process-#{session_id}"}
  end

  defp active_fence do
    state = ExecutionFence.new()

    {:ok, state1, token} =
      ExecutionFence.admit(state, %{issue_id: "HGS-300", repository: "orchestrator", branch: "hgs-300", worktree: "worktree"}, 0)

    {:ok, state, :registered} =
      ExecutionFence.register(
        state1,
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
