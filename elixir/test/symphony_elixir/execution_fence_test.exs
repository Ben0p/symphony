defmodule SymphonyElixir.ExecutionFenceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionFence

  @issue "HGS-294"
  @repository "hypergridau/dahlia"
  @branch "codex/hgs-294"
  @worktree "C:/code/hypergrid.au/_worktrees/hgs-294"

  test "admits one generation and registers one worker plus reviewers" do
    {:ok, state, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)

    assert {:ok, state, :registered} =
             ExecutionFence.register(state, token, :worker, session("worker-1", 100), 100)

    assert {:ok, state, :registered} =
             ExecutionFence.register(state, token, :reviewer, session("reviewer-1", 100), 100)

    assert state.executions[@issue].generation == 1
    assert map_size(state.executions[@issue].leases) == 2

    assert {:ok, %{generation: 1, action: :commit}} =
             ExecutionFence.authorize(state, token, :commit)
  end

  test "persists an exact head observation on the generation-bound worker lease" do
    {:ok, state, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)

    {:ok, state, :registered} =
      ExecutionFence.register(state, token, :worker, session("worker-1", 100), 100)

    assert {:ok, state} =
             ExecutionFence.observe_session_head(state, token, "worker-1", "def456", 110)

    assert state.executions[@issue].leases["worker-1"].head == "def456"
    assert state.sessions["worker-1"].head == "def456"
    assert state.sessions["worker-1"].last_heartbeat_at == 110
  end

  test "terminal fencing rejects stale mutation and waits for every lease before cleanup" do
    {:ok, state, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)

    {:ok, state, :registered} =
      ExecutionFence.register(state, token, :worker, session("worker-1", 100), 100)

    {:ok, state, :registered} =
      ExecutionFence.register(state, token, :reviewer, session("reviewer-1", 100), 100)

    {:ok, state, :fenced} = ExecutionFence.fence(state, token, terminal(), 200)
    assert {:ok, ^state, :already_fenced} = ExecutionFence.fence(state, token, terminal(), 201)
    assert {:error, :terminal_fenced} = ExecutionFence.authorize(state, token, :push)

    assert {:error, {:leases_active, ["reviewer-1", "worker-1"]}} =
             ExecutionFence.cleanup(state, token, "abc123", 201)

    {:ok, state, :released} = ExecutionFence.release(state, token, "worker-1", :worker_exit)

    assert {:error, {:leases_active, ["reviewer-1"]}} =
             ExecutionFence.cleanup(state, token, "abc123", 202)

    {:ok, state, :released} = ExecutionFence.release(state, token, "reviewer-1", :review_complete)

    assert {:ok, state, :cleaned} = ExecutionFence.cleanup(state, token, "abc123", 203)
    assert {:ok, ^state, :already_cleaned} = ExecutionFence.cleanup(state, token, "abc123", 204)
  end

  test "cleanup rejects a head that diverged after terminal fencing" do
    {:ok, state, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)
    {:ok, state, :fenced} = ExecutionFence.fence(state, token, terminal(), 110)

    assert {:error, :head_diverged} = ExecutionFence.cleanup(state, token, "def456", 120)
  end

  test "records exactly one durable triage record for a post-terminal head divergence" do
    {:ok, state, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)
    {:ok, state, :fenced} = ExecutionFence.fence(state, token, terminal(), 110)

    assert {:ok, state, :recorded} =
             ExecutionFence.record_head_divergence(state, token, "abc123", "def456", 120)

    assert [%{type: :post_terminal_head_divergence, expected_head: "abc123", observed_head: "def456"}] =
             ExecutionFence.snapshot(state).triage_records

    assert {:ok, same_state, :already_recorded} =
             ExecutionFence.record_head_divergence(state, token, "abc123", "ghi789", 121)

    assert same_state == state
    assert length(ExecutionFence.snapshot(same_state).triage_records) == 1
  end

  test "stale generations fail closed and cannot clean a newer generation" do
    {:ok, state, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)
    {:ok, state, :fenced} = ExecutionFence.fence(state, token, terminal(), 110)
    {:ok, state, :cleaned} = ExecutionFence.cleanup(state, token, "abc123", 120)

    {:ok, state, next_token} = ExecutionFence.admit(state, admission(), 130)
    assert next_token.generation == 2

    {:ok, state, :registered} =
      ExecutionFence.register(
        state,
        next_token,
        :worker,
        Map.put(session("worker-2", 130), :generation, 2),
        130
      )

    assert {:error, :stale_generation} = ExecutionFence.authorize(state, token, :commit)
    assert {:error, :stale_generation} = ExecutionFence.cleanup(state, token, "abc123", 131)
    assert {:error, :generation_active} = ExecutionFence.admit(state, admission(), 132)
  end

  test "a released generation is quiescent and the next admission gets a new generation" do
    {:ok, state, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)

    {:ok, state, :registered} =
      ExecutionFence.register(state, token, :worker, session("worker-1", 100), 100)

    {:ok, state, :released} = ExecutionFence.release(state, token, "worker-1", :worker_exit)

    assert {:ok, state, next_token} = ExecutionFence.admit(state, admission(), 110)
    assert next_token.generation == 2
    assert {:error, :stale_generation} = ExecutionFence.authorize(state, token, :commit)
  end

  test "reconciliation blocks unknown and contradictory ownership, then expires a missing lease" do
    {:ok, state, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)

    {:ok, state, :registered} =
      ExecutionFence.register(state, token, :worker, session("worker-1", 100), 100)

    unknown = Map.put(session("unknown-1", 100), :issue_id, @issue)

    assert {:ok, state, %{status: :blocked, unknown: ["unknown-1", "worker-1"]}} =
             ExecutionFence.reconcile_sessions(state, [unknown], 101, 50)

    contradictory = Map.put(session("worker-1", 101), :branch, "codex/other")

    assert {:ok, state, %{status: :blocked, contradictory: ["worker-1"]}} =
             ExecutionFence.reconcile_sessions(state, [contradictory], 102, 50)

    {:ok, state, %{status: :reconciled, expired: ["worker-1"]}} =
      ExecutionFence.reconcile_sessions(state, [], 200, 50)

    assert state.executions[@issue].leases["worker-1"].status == :expired
  end

  test "terminal state dominates a stale non-terminal session observation" do
    {:ok, state, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)

    {:ok, state, :registered} =
      ExecutionFence.register(state, token, :worker, session("worker-1", 100), 100)

    {:ok, state, :fenced} = ExecutionFence.fence(state, token, terminal(), 110)

    stale = session("worker-1", 111)

    assert {:ok, _state, %{status: :blocked, contradictory: ["worker-1"]}} =
             ExecutionFence.reconcile_sessions(state, [stale], 111, 50)
  end

  test "serialized concurrent terminal observations are idempotent" do
    {:ok, initial, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)
    {:ok, agent} = Agent.start_link(fn -> initial end)

    results =
      1..8
      |> Task.async_stream(fn _ ->
        Agent.get_and_update(agent, fn state ->
          case ExecutionFence.fence(state, token, terminal(), 110) do
            {:ok, next_state, result} -> {result, next_state}
            {:error, reason} -> {reason, state}
          end
        end)
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :fenced)) == 1
    assert Enum.count(results, &(&1 == :already_fenced)) == 7
  end

  test "malformed snapshots and invalid heartbeat clocks fail closed" do
    malformed = %{schema_version: 1, executions: %{"bad" => :bad}, sessions: %{}, history: []}

    assert {:error, :invalid_state} =
             ExecutionFence.admit(malformed, admission(), 100)

    {:ok, state, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)

    {:ok, state, :registered} =
      ExecutionFence.register(state, token, :worker, session("worker-1", 100), 100)

    assert {:error, :invalid_session} = ExecutionFence.heartbeat(state, token, "worker-1", -1)

    assert {:error, :invalid_session} =
             ExecutionFence.heartbeat(state, token, "worker-1", "later")
  end

  test "state validation rejects a lease missing from the top-level registry" do
    {:ok, state, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)

    {:ok, state, :registered} =
      ExecutionFence.register(state, token, :worker, session("worker-1", 100), 100)

    invalid = %{state | sessions: %{}}

    assert {:error, :invalid_state} = ExecutionFence.validate(invalid)
  end

  test "state validation rejects malformed history" do
    invalid = %{ExecutionFence.new() | history: [%{issue_id: "missing-execution-fields"}]}

    assert {:error, :invalid_state} = ExecutionFence.validate(invalid)
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
