defmodule SymphonyElixir.ResponsibilityGraphRestartExpiryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{ExecutionFence, ResponsibilityGraph}

  @actions [:read, :observe, :delegate, :reconcile, :edit, :commit, :push, :state_mutation, :cleanup, :review, :report]
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
    actions: @actions
  }
  @authority %{class: :routine_engineering, capabilities: @scope.actions, environments: ["local"]}
  @budget %{model: "luna", effort: :max, max_tokens: 10_000, max_children: 4}
  @lease %{issue_id: "HGS-300", repository: "orchestrator", generation: 1, session_id: "worker", process_id: "process-worker"}

  test "nil-lease authority reconciles just before expiry but rejects the boundary and later times" do
    graph = ResponsibilityGraph.new() |> delegate!("owner", :accountable, 0, expires_at_ms: 10) |> restart!()
    assert {:ok, restored} = ResponsibilityGraph.reconcile_delegation(graph, "owner", nil, 9)
    assert :ok = ResponsibilityGraph.validate(restored)
    assert restored.delegations["owner"].runtime_lease == nil

    for now <- [10, 11] do
      assert {:error, :delegation_expired} = ResponsibilityGraph.reconcile_delegation(graph, "owner", nil, now)
    end
  end

  test "bound authority preserves the same expiry boundary" do
    graph = pair([expires_at_ms: 10], expires_at_ms: 20) |> restart!()
    {:ok, graph} = ResponsibilityGraph.reconcile_delegation(graph, "owner", nil, 2)
    assert {:ok, restored} = ResponsibilityGraph.reconcile_delegation(graph, "worker", @lease, 9)
    assert :ok = ResponsibilityGraph.validate(restored)
    assert restored.delegations["worker"].runtime_lease == @lease
    assert restored.delegations["worker"].last_heartbeat_at == 9
    assert restored.delegations["worker"].blocked_on == nil

    for now <- [10, 11] do
      assert {:error, :delegation_expired} = ResponsibilityGraph.reconcile_delegation(graph, "worker", @lease, now)
    end
  end

  test "an expired active parent blocks a child before and after global reconciliation" do
    graph = pair([expires_at_ms: 20], expires_at_ms: 10) |> restart!()
    {:ok, graph} = ResponsibilityGraph.reconcile_delegation(graph, "owner", nil, 2)
    assert graph.delegations["owner"].status == :active
    assert {:error, :delegation_expired} = ResponsibilityGraph.reconcile_delegation(graph, "worker", @lease, 10)
    assert {:ok, expired, %{expired: ["owner"]}} = ResponsibilityGraph.reconcile(graph, 10)
    assert {:error, :parent_not_reconciled} = ResponsibilityGraph.reconcile_delegation(expired, "worker", @lease, 10)
  end

  test "restart reconciliation rejects a heartbeat clock regression" do
    {:ok, graph} = ResponsibilityGraph.heartbeat(pair(), "worker", 5)
    graph = restart!(graph)
    {:ok, graph} = ResponsibilityGraph.reconcile_delegation(graph, "owner", nil, 6)
    assert {:error, :delegation_clock_regression} = ResponsibilityGraph.reconcile_delegation(graph, "worker", @lease, 4)
    assert {:ok, restored} = ResponsibilityGraph.reconcile_delegation(graph, "worker", @lease, 5)
    assert restored.delegations["worker"].last_heartbeat_at == 5
    assert :ok = ResponsibilityGraph.validate(restored)
  end

  test "restart reconciliation requires the exact persisted generation, session and process" do
    graph = pair() |> restart!()
    {:ok, graph} = ResponsibilityGraph.reconcile_delegation(graph, "owner", nil, 2)

    for changed <- [%{@lease | generation: 2}, %{@lease | session_id: "other"}, %{@lease | process_id: "other"}] do
      assert {:error, :runtime_lease_conflict} = ResponsibilityGraph.reconcile_delegation(graph, "worker", changed, 3)
    end

    for changed <- [%{@lease | issue_id: "HGS-999"}, %{@lease | repository: "other"}] do
      assert {:error, :runtime_scope_mismatch} = ResponsibilityGraph.reconcile_delegation(graph, "worker", changed, 3)
    end

    assert {:error, :invalid_runtime_lease} = ResponsibilityGraph.reconcile_delegation(graph, "worker", nil, 3)
    assert {:ok, restored} = ResponsibilityGraph.reconcile_delegation(graph, "worker", @lease, 3)
    assert :ok = ResponsibilityGraph.validate(restored)
  end

  test "accountable reconciliation cannot add or clear a persisted lease" do
    for {old, replacement} <- [{nil, @lease}, {@lease, nil}] do
      graph = ResponsibilityGraph.new() |> delegate!("owner", :accountable, 0, runtime_lease: old) |> restart!()
      assert {:error, :runtime_lease_conflict} = ResponsibilityGraph.reconcile_delegation(graph, "owner", replacement, 1)
      assert {:ok, restored} = ResponsibilityGraph.reconcile_delegation(graph, "owner", old, 1)
      assert restored.delegations["owner"].runtime_lease == old
    end
  end

  test "restart preserves an unbound responsible delegation for its first binding" do
    graph = pair(runtime_lease: nil) |> restart!()
    assert graph.delegations["owner"].status == :blocked
    assert graph.delegations["worker"].status == :active
    assert graph.delegations["worker"].runtime_lease == nil
    {:ok, graph} = ResponsibilityGraph.reconcile_delegation(graph, "owner", nil, 2)
    assert {:ok, bound} = ResponsibilityGraph.bind_runtime_lease(graph, "worker", @lease, 3)
    assert bound.delegations["worker"].runtime_lease == @lease
    assert :ok = ResponsibilityGraph.validate(bound)
  end

  test "global expiry preserves active and restart-blocked records and appends each expiry once" do
    for restarted? <- [false, true] do
      initial = pair([expires_at_ms: 10], expires_at_ms: 10)
      graph = if restarted?, do: restart!(initial), else: initial
      assert {:ok, expired, %{expired: ["owner", "worker"]}} = ResponsibilityGraph.reconcile(graph, 10)

      for id <- ["owner", "worker"] do
        before = graph.delegations[id]
        after_expiry = expired.delegations[id]
        assert after_expiry == %{before | status: :expired, terminal_reason: :lease_expired}
      end

      assert expired.delegations["worker"].runtime_lease == @lease
      assert Enum.drop(expired.events, 2) == graph.events

      assert Enum.take(expired.events, 2) == [
               %{type: :expired, delegation_id: "worker", at_ms: 10, details: %{}},
               %{type: :expired, delegation_id: "owner", at_ms: 10, details: %{}}
             ]

      assert length(expired.events) == length(graph.events) + 2
      assert :ok = ResponsibilityGraph.validate(expired)
      assert {:ok, ^expired, %{expired: []}} = ResponsibilityGraph.reconcile(expired, 10)
      assert {:ok, ^expired, %{expired: []}} = ResponsibilityGraph.reconcile(expired, 11)
    end
  end

  test "global expiry leaves an arbitrary blocked reason untouched" do
    graph = ResponsibilityGraph.new() |> delegate!("owner", :accountable, 0, expires_at_ms: 10)
    {:ok, blocked, _impact} = ResponsibilityGraph.block(graph, "owner", :manual_review, 1)
    assert blocked.delegations["owner"].blocked_on == :manual_review
    assert {:ok, ^blocked, %{expired: []}} = ResponsibilityGraph.reconcile(blocked, 10)
  end

  test "expired authority denies mutation while the independent execution fence remains active" do
    graph = pair([expires_at_ms: 10], expires_at_ms: 10)
    {fence, token} = active_fence()
    assert {:ok, _} = ResponsibilityGraph.authorize_with_execution_fence(graph, "worker", :commit, fence)
    assert {:ok, expired, %{expired: ["owner", "worker"]}} = ResponsibilityGraph.reconcile(graph, 10)

    assert {:error, {:delegation_not_active, :expired}} =
             ResponsibilityGraph.authorize_with_execution_fence(expired, "worker", :commit, fence)

    assert {:ok, _} = ExecutionFence.authorize(fence, token, :commit)
    assert expired.delegations["worker"].runtime_lease == @lease
  end

  test "output validation prevents two active accountable owners after restart" do
    graph = ResponsibilityGraph.new() |> delegate!("old-owner", :accountable, 0) |> restart!()
    graph = delegate!(graph, "new-owner", :accountable, 1)
    assert :ok = ResponsibilityGraph.validate(graph)
    assert {:error, :invalid_state} = ResponsibilityGraph.reconcile_delegation(graph, "old-owner", nil, 2)
  end

  defp pair(worker_overrides \\ [], owner_overrides \\ []) do
    worker = Keyword.merge([parent_delegation_id: "owner", runtime_lease: @lease], worker_overrides)

    ResponsibilityGraph.new()
    |> delegate!("owner", :accountable, 0, owner_overrides)
    |> delegate!("worker", :responsible, 1, worker)
  end

  defp delegate!(graph, id, role, now, overrides \\ []) do
    attrs = %{
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
    }

    {:ok, next, _delegation} = ResponsibilityGraph.delegate(graph, Map.merge(attrs, Map.new(overrides)), now)
    next
  end

  defp restart!(graph) do
    {:ok, restarted} = ResponsibilityGraph.mark_unreconciled_after_restart(graph)
    restarted
  end

  defp active_fence do
    scope = %{issue_id: "HGS-300", repository: "orchestrator", branch: "hgs-300", worktree: "worktree"}
    {:ok, fence, token} = ExecutionFence.admit(ExecutionFence.new(), scope, 0)

    identity = %{
      session_id: "worker",
      process_id: "process-worker",
      branch: "hgs-300",
      worktree: "worktree",
      linear_state: "In Progress",
      pr_state: "none",
      head: "abc123",
      last_heartbeat_at: 0
    }

    {:ok, fence, :registered} = ExecutionFence.register(fence, token, :worker, identity, 0)
    {fence, token}
  end
end
