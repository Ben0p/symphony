defmodule SymphonyElixir.ReviewHandoffTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.ReviewHandoff
  alias SymphonyElixir.Tracker.Issue

  @head String.duplicate("a", 40)
  @merge String.duplicate("b", 40)

  defp execution(id \\ "issue", repository \\ "hypergridau/grid") do
    scope = %{issue_id: id, repository: repository, generation: 1, worktree: "/work/#{id}", branch: "tracker-branch"}
    lease = Map.merge(scope, %{session_id: "worker:#{id}:1", process_id: "logical:#{id}:1", role: :worker, status: :released, supervisor_identity: %{unit: "owned.scope"}, extra_metadata: true})
    Map.merge(scope, %{worker_host: nil, status: :active, terminal: nil, cleanup: :pending, leases: %{lease.session_id => lease}, extra_metadata: true})
  end

  defp snapshot(repository \\ "hypergridau/grid"), do: %{head: @head, branch: "actual-branch", repository: repository, status: ""}

  defp pr(repository \\ "hypergridau/grid") do
    %{
      "state" => "MERGED",
      "headRefName" => "actual-branch",
      "headRefOid" => @head,
      "baseRefName" => "main",
      "mergeCommit" => %{"oid" => @merge},
      "mergedAt" => "2026-09-10T18:00:00Z",
      "number" => 222,
      "url" => "https://github.com/#{repository}/pull/222"
    }
  end

  test "entry preserves the complete native issue and exact logical session" do
    issue = %Issue{id: "issue", identifier: "HGS-498", state: "In Review", title: "Useful work"}
    assert {:ok, entry} = ReviewHandoff.entry(execution(), issue)
    assert entry.issue == issue
    assert entry.execution_token == %{issue_id: "issue", generation: 1}
    assert entry.execution_session_id == "worker:issue:1"
    assert entry.process_id == "logical:issue:1"
  end

  test "malformed, live, stale, failed and ambiguous leases fail closed" do
    source = execution()
    lease = source.leases["worker:issue:1"]

    invalid = [
      nil,
      %{},
      %{source | generation: 0},
      Map.delete(source, :worker_host),
      %{source | worker_host: "remote"},
      %{source | leases: %{}},
      put_in(source, [:leases, "worker:issue:1", :generation], 2),
      put_in(source, [:leases, "worker:issue:1", :status], :active),
      put_in(source, [:leases, "worker:issue:1", :process_id], 111),
      put_in(source, [:leases, "worker:issue:1", :supervisor_identity], nil),
      put_in(source, [:leases, "second"], %{lease | session_id: "second"}),
      %{source | status: :terminal, terminal: %{failure_evidence_ref: "failed"}}
    ]

    for candidate <- invalid, do: assert({:error, _} = ReviewHandoff.entry(candidate, %{id: "issue"}))
  end

  test "invalid and running rows do not stop another independent repository" do
    a = execution("a")
    b = execution("b", "hypergridau/another")

    rows = %{
      "a" => a,
      "b" => b,
      "c" => %{execution("c") | cleanup: :cleaned},
      "d" => %{execution("d") | generation: 0},
      "e" => execution("e")
    }

    assert [{"a", ^a}, {"b", ^b}] = ReviewHandoff.pending_executions(%{executions: rows}, ["e"])
  end

  test "current actual branch accepts a unique merge in either repository" do
    for repository <- ["hypergridau/grid", "hypergridau/another"] do
      assert {:ok, %{accepted_head: @head, merge_identity: @merge}} =
               ReviewHandoff.accepted_merge(execution("issue", repository), snapshot(repository), [pr(repository)])
    end
  end

  test "open branch, ambiguity, dirty workspace and stale evidence cannot authorize cleanup" do
    open = pr() |> Map.merge(%{"state" => "OPEN", "mergeCommit" => nil, "mergedAt" => nil})

    for prs <- [
          [open, pr()],
          [pr(), pr()],
          [Map.put(pr(), "headRefOid", @merge)],
          [Map.put(pr(), "url", "https://github.com/other/repo/pull/222")],
          [Map.put(pr(), "mergeCommit", nil)],
          [Map.put(pr(), "mergedAt", nil)],
          [nil],
          []
        ] do
      assert {:error, _} = ReviewHandoff.accepted_merge(execution(), snapshot(), prs)
    end

    assert {:error, _} = ReviewHandoff.accepted_merge(execution(), %{snapshot() | status: "?? evidence.txt"}, [pr()])
    assert {:error, _} = ReviewHandoff.accepted_merge(execution(), snapshot("other/repo"), [pr()])
  end
end
