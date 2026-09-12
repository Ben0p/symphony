defmodule SymphonyElixir.ResponsibilityGraphReleaseRuntimeLeaseTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ResponsibilityGraph
  alias SymphonyElixir.ResponsibilityGraph.Persistence

  @moduletag :tmp_dir
  @actions [:read, :observe, :delegate, :reconcile, :edit, :commit, :push, :state_mutation, :cleanup, :review, :report]
  @scope %{
    company_id: "hypergrid",
    objective_id: "objective-1",
    initiative_id: "initiative-1",
    project_id: "project-1",
    work_package_id: "package-1",
    issue_id: "HGS-520",
    repository: "orchestrator",
    paths: [],
    modules: [],
    environments: ["local"],
    actions: @actions
  }
  @authority %{class: :routine_engineering, capabilities: @scope.actions, environments: ["local"]}
  @budget %{model: "luna", effort: :high, max_tokens: 10_000, max_children: 2}
  @lease %{issue_id: "HGS-520", repository: "orchestrator", generation: 1, session_id: "worker", process_id: "process-worker"}

  test "release before, at, and after expiry preserves delegation and records actual time" do
    graph = fixture()
    before = graph.delegations["worker"]

    for now <- [9, 10, 11] do
      assert {:ok, next, :released} =
               ResponsibilityGraph.release_runtime_lease(graph, "worker", @lease, now)

      assert next.delegations["worker"] == %{before | runtime_lease: nil}
      assert next.delegations["owner"] == graph.delegations["owner"]
      assert tl(next.events) == graph.events
      assert [%{type: :runtime_lease_released, delegation_id: "worker", at_ms: ^now, details: %{}} | _] = next.events
      assert :ok = ResponsibilityGraph.validate(next)
    end
  end

  test "nil lease is an exact no-op and mismatches conflict" do
    graph = fixture()

    {:ok, released, :released} =
      ResponsibilityGraph.release_runtime_lease(graph, "worker", @lease, 9)

    assert {:ok, ^released, :already_released} =
             ResponsibilityGraph.release_runtime_lease(released, "worker", @lease, 11)

    for {field, value} <- [issue_id: "other", repository: "other", generation: 2, session_id: "other", process_id: "other"] do
      assert {:error, :runtime_lease_conflict} =
               ResponsibilityGraph.release_runtime_lease(
                 graph,
                 "worker",
                 Map.put(@lease, field, value),
                 9
               )
    end
  end

  test "invalid state, clock regression, and reconciled expiry fail closed" do
    assert {:error, :invalid_state} =
             ResponsibilityGraph.release_runtime_lease(%{}, "worker", @lease, 9)

    graph = fixture()

    assert {:error, :delegation_clock_regression} =
             ResponsibilityGraph.release_runtime_lease(graph, "worker", @lease, 0)

    assert {:ok, expired, %{expired: ["owner", "worker"]}} =
             ResponsibilityGraph.reconcile(graph, 10)

    assert {:error, {:delegation_not_active, :expired}} =
             ResponsibilityGraph.release_runtime_lease(expired, "worker", @lease, 10)
  end

  test "released graph and failed closure persist valid state", %{tmp_dir: dir} do
    graph = fixture()

    {:ok, released, :released} =
      ResponsibilityGraph.release_runtime_lease(graph, "worker", @lease, 11)

    path = Path.join(dir, "graph.json")
    assert :ok = Persistence.save(path, released)
    assert {:ok, loaded} = Persistence.load(path)
    assert :ok = ResponsibilityGraph.validate(loaded)
    assert loaded.delegations == released.delegations

    assert {:ok, failed, impact} =
             ResponsibilityGraph.fail(loaded, "owner", :budget_exceeded, 12)

    assert failed.delegations["owner"].status == :failed
    assert failed.delegations["worker"].status == :revoked
    assert impact.execution_leases == []
    assert :ok = ResponsibilityGraph.validate(failed)
    assert :ok = Persistence.save(path, failed)
    assert {:ok, persisted} = Persistence.load(path)
    assert :ok = ResponsibilityGraph.validate(persisted)

    for id <- ["owner", "worker"] do
      fields = [:accepted_at_ms, :last_heartbeat_at, :expires_at_ms, :runtime_lease, :budget]
      assert Map.take(persisted.delegations[id], fields) == Map.take(released.delegations[id], fields)
      assert persisted.delegations[id].status == failed.delegations[id].status
    end

    assert {:error, {:delegation_not_active, :revoked}} =
             ResponsibilityGraph.release_runtime_lease(persisted, "worker", @lease, 13)
  end

  defp fixture do
    ResponsibilityGraph.new()
    |> delegate!("owner", :accountable, 0)
    |> delegate!("worker", :responsible, 1, parent_delegation_id: "owner", runtime_lease: @lease)
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
      expires_at_ms: 10,
      expected_deliverable: "bounded deliverable",
      expected_evidence: "tests and review evidence",
      return_to_parent: %{owner_id: "owner", contract: "return evidence and outcome"}
    }

    {:ok, next, _} =
      ResponsibilityGraph.delegate(graph, Map.merge(attrs, Map.new(overrides)), now)

    next
  end
end
