Code.require_file("../support/managed_responsibility_fixture.exs", __DIR__)

defmodule SymphonyElixir.ManagedResponsibilityTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{ManagedResponsibility, ResponsibilityGraph}
  alias SymphonyElixir.ManagedResponsibilityFixture, as: Fixture

  setup do
    now = System.system_time(:millisecond)
    {:ok, manifest} = ManagedResponsibility.decode(Fixture.payload(now), Fixture.context(), now)
    %{now: now, manifest: manifest}
  end

  test "an explicitly empty batch authorizes no issue", %{now: now} do
    payload = Map.put(Fixture.payload(now), "entries", [])
    assert {:ok, empty} = ManagedResponsibility.decode(payload, Fixture.context(), now)
    assert {:error, _} = ManagedResponsibility.admit(ResponsibilityGraph.new(), empty, Fixture.issue(1), now)
  end

  test "the selected responsible actor must be the configured managed runner", %{now: now} do
    assert {:error, _} = ManagedResponsibility.decode(Fixture.payload(now), Map.delete(Fixture.context(), :runner_id), now)
    context = Map.put(Fixture.context(), :runner_id, "wrong-runner")
    assert {:error, _} = ManagedResponsibility.decode(Fixture.payload(now), context, now)
  end

  test "operator intents stay inert until one exact issue is admitted and replay is unchanged", %{manifest: manifest, now: now} do
    graph = ResponsibilityGraph.new()
    assert graph.delegations == %{}
    assert {:ok, admitted} = ManagedResponsibility.admit(graph, manifest, Fixture.issue(1), now)
    assert map_size(admitted.delegations) == 2
    assert admitted.delegations["responsible-1"].runtime_lease == nil
    assert {:ok, ^admitted} = ManagedResponsibility.admit(admitted, manifest, Fixture.issue(1), now + 1)
    assert {:error, _} = ManagedResponsibility.admit(admitted, manifest, Fixture.issue(2), now + 1)
  end

  test "owner, identifier, scope, expiry and duplicate input mismatches fail before graph writes", %{now: now, manifest: manifest} do
    raw = Fixture.payload(now)
    first = hd(raw["entries"])

    cases = [
      Map.put(raw, "schema_version", 2),
      Map.put(raw, "pool_key", "other"),
      Map.put(raw, "repository_ref", "other/repo"),
      Map.put(raw, "managed_project_profile_id", "other"),
      Map.put(raw, "entries", [first, first]),
      Map.put(raw, "runtime_lease", %{}),
      put_in(raw, ["entries", Access.at(0), "responsible", "status"], "active"),
      put_in(raw, ["entries", Access.at(0), "responsible", "scope", "environment"], "production"),
      put_in(raw, ["entries", Access.at(0), "responsible", "authority", "unlimited"], true),
      put_in(raw, ["entries", Access.at(0), "responsible", "budget", "tokens"], 0),
      put_in(raw, ["entries", Access.at(0), "responsible", "return_to_parent", "silent"], true),
      put_in(raw, ["entries", Access.at(0), "responsible", "scope", "issue_id"], Fixture.issue(2).id),
      put_in(raw, ["entries", Access.at(0), "responsible", "scope", "paths"], ["../outside"]),
      put_in(raw, ["entries", Access.at(0), "responsible", "authority", "environments"], ["production"]),
      put_in(raw, ["entries", Access.at(0), "responsible", "budget", "max_children"], 1),
      put_in(raw, ["entries", Access.at(0), "responsible", "expires_at_ms"], now)
    ]

    for candidate <- cases, do: assert({:error, _} = ManagedResponsibility.decode(candidate, Fixture.context(), now))
    assert {:error, _} = ManagedResponsibility.admit(ResponsibilityGraph.new(), manifest, %{Fixture.issue(1) | assignee_id: "other"}, now)
    assert {:error, _} = ManagedResponsibility.admit(ResponsibilityGraph.new(), manifest, %{Fixture.issue(1) | identifier: "HGS-999"}, now)
    assert {:error, _} = ManagedResponsibility.admit(ResponsibilityGraph.new(), manifest, Fixture.issue(1), now + 60_001)
  end

  test "replay cannot revive terminal or blocked authority or widen an existing grant", %{manifest: manifest, now: now} do
    {:ok, graph} = ManagedResponsibility.admit(ResponsibilityGraph.new(), manifest, Fixture.issue(1), now)
    {:ok, completed, _} = ResponsibilityGraph.complete(graph, "responsible-1", %{source: "reviewed"}, now + 1)
    assert {:error, _} = ManagedResponsibility.admit(completed, manifest, Fixture.issue(1), now + 2)
    assert {:ok, _} = ManagedResponsibility.admit(completed, manifest, Fixture.issue(2), now + 2)
    {:ok, blocked, _} = ResponsibilityGraph.block(graph, "responsible-1", :review_required, now + 1)
    assert {:error, _} = ManagedResponsibility.admit(blocked, manifest, Fixture.issue(1), now + 2)
    assert {:error, _} = ManagedResponsibility.admit(blocked, manifest, Fixture.issue(2), now + 2)
    changed = put_in(manifest, [:entries, Access.at(0), :responsible, :expected_deliverable], "Different scope")
    assert {:error, _} = ManagedResponsibility.admit(graph, changed, Fixture.issue(1), now + 2)
  end
end
