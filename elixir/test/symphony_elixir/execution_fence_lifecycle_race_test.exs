defmodule SymphonyElixir.ExecutionFenceLifecycleRaceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionFence

  @issue "HGS-294-race"
  @repository "hypergridau/dahlia"
  @branch "codex/hgs-294-race"
  @worktree "C:/code/hypergrid.au/_worktrees/hgs-294-race"

  test "merge fences stale callbacks before quiescent cleanup and next admission" do
    {:ok, state, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)

    {:ok, state, :registered} =
      ExecutionFence.register(state, token, :worker, session("worker-1", 100), 100)

    {:ok, state, :registered} =
      ExecutionFence.register(state, token, :reviewer, session("reviewer-1", 100), 100)

    {:ok, fenced, :fenced} = ExecutionFence.fence(state, token, terminal(), 200)

    callbacks = [
      {:worker_push, fn -> ExecutionFence.authorize(fenced, token, :push) end},
      {:reviewer_state_mutation, fn -> ExecutionFence.authorize(fenced, token, :state_mutation) end},
      {:cleanup, fn -> ExecutionFence.cleanup(fenced, token, "abc123", 201) end},
      {:delayed_worker_observation,
       fn ->
         ExecutionFence.reconcile_sessions(
           fenced,
           [Map.put(session("worker-1", 201), :branch, "codex/other")],
           201,
           50
         )
       end}
    ]

    results =
      callbacks
      |> Task.async_stream(fn {name, callback} -> {name, callback.()} end, max_concurrency: 4)
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.sort_by(&elem(&1, 0))

    assert [
             cleanup: {:error, {:leases_active, ["reviewer-1", "worker-1"]}},
             delayed_worker_observation: {
               :ok,
               %{
                 executions: %{@issue => %{status: :terminal}},
                 sessions: %{"worker-1" => %{status: :active}},
                 history: [],
                 triage_records: %{}
               },
               %{status: :blocked, contradictory: ["worker-1"]}
             },
             reviewer_state_mutation: {:error, :terminal_fenced},
             worker_push: {:error, :terminal_fenced}
           ] = results

    {:ok, released_worker, :released} =
      ExecutionFence.release(fenced, token, "worker-1", :worker_exit)

    {:ok, released_all, :released} =
      ExecutionFence.release(released_worker, token, "reviewer-1", :review_complete)

    assert {:ok, cleaned, :cleaned} =
             ExecutionFence.cleanup(released_all, token, "abc123", 202)

    assert {:ok, ^cleaned, :already_cleaned} =
             ExecutionFence.cleanup(cleaned, token, "abc123", 203)

    assert {:error, :terminal_fenced} = ExecutionFence.authorize(cleaned, token, :commit)

    {:ok, next_state, next_token} = ExecutionFence.admit(cleaned, admission(), 204)
    assert next_token.generation == 2
    assert {:error, :stale_generation} = ExecutionFence.authorize(next_state, token, :push)
  end

  defp admission do
    %{issue_id: @issue, repository: @repository, branch: @branch, worktree: @worktree}
  end

  defp terminal do
    %{terminal_state: "Done", accepted_head: "abc123", merge_identity: "merge-1"}
  end

  defp session(id, heartbeat) do
    %{
      issue_id: @issue,
      repository: @repository,
      generation: 1,
      role: :worker,
      session_id: id,
      process_id: "process-#{id}",
      branch: @branch,
      worktree: @worktree,
      linear_state: "In Progress",
      pr_state: "OPEN",
      head: "abc123",
      last_heartbeat_at: heartbeat
    }
  end
end
