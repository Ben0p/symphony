defmodule SymphonyElixir.ExecutionFence.FailedAttemptTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionFence
  alias SymphonyElixir.ExecutionFence.{FailedAttempt, Persistence}

  @issue "HGS-488"
  @repository "hypergridau/dahlia"
  @branch "codex/hgs-488"
  @worktree "C:/fixture/hgs-488"
  @head String.duplicate("a", 40)
  @failure_ref "sha256:" <> String.duplicate("b", 64)
  @termination_ref "sha256:" <> String.duplicate("c", 64)

  test "records an attempt failure without changing tracker observations or lease history" do
    {state, token} = confirmed()
    assert {:ok, failed, :fenced} = FailedAttempt.record(state, token, attrs(), 120)

    assert failed.executions[@issue].terminal == %{
             state: "Failed attempt",
             accepted_head: @head,
             merge_identity: nil,
             observed_at_ms: 120,
             failure_evidence_ref: @failure_ref
           }

    assert failed.executions[@issue].status == :terminal
    assert failed.executions[@issue].cleanup == :pending
    assert failed.executions[@issue].leases == state.executions[@issue].leases
    assert failed.sessions == state.sessions
    assert failed.history == state.history
    assert {:error, :terminal_fenced} = ExecutionFence.authorize(failed, token, :commit)
    assert {:ok, ^failed, :already_fenced} = FailedAttempt.record(failed, token, attrs(), 130)

    assert {:error, :terminal_conflict} =
             FailedAttempt.record(failed, token, %{attrs() | accepted_head: String.duplicate("c", 40)}, 130)

    assert {:error, :terminal_conflict} =
             FailedAttempt.record(failed, token, %{attrs() | failure_evidence_ref: "sha256:" <> String.duplicate("d", 64)}, 130)
  end

  test "rejects stale, missing and malformed identity without accepting duplicate attribute identity" do
    {state, token} = confirmed()

    for invalid <- [%{token | generation: 2}, %{token | issue_id: "other"}, %{}, nil, %{issue_id: @issue, generation: "1"}] do
      assert {:error, _} = FailedAttempt.record(state, invalid, attrs(), 120)
    end

    assert {:error, :invalid_failure_attributes} =
             FailedAttempt.record(state, token, Map.put(attrs(), :issue_id, @issue), 120)
  end

  test "rejects malformed failure evidence and time" do
    {state, token} = confirmed()

    invalid_attributes = [
      nil,
      %{},
      %{accepted_head: String.duplicate("a", 39), failure_evidence_ref: @failure_ref},
      %{accepted_head: @head, failure_evidence_ref: "sha256:" <> String.duplicate("B", 64)}
    ]

    for invalid <- invalid_attributes do
      assert {:error, _} = FailedAttempt.record(state, token, invalid, 120)
    end

    assert {:error, _} = FailedAttempt.record(state, token, attrs(), -1)
  end

  test "refuses to rewrite an ordinary terminal outcome" do
    {state, token} = confirmed()
    {:ok, done, :fenced} = ExecutionFence.fence(state, token, %{terminal_state: "Done", accepted_head: @head}, 120)
    assert {:error, :terminal_conflict} = FailedAttempt.record(done, token, attrs(), 130)
  end

  test "requires evidence of an actual terminated worker" do
    {:ok, state, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)
    assert {:error, :worker_termination_missing} = FailedAttempt.record(state, token, attrs(), 120)
    {:ok, state, :registered} = ExecutionFence.register(state, token, :worker, session("worker-1"), 100)
    assert {:error, :worker_termination_missing} = FailedAttempt.record(state, token, attrs(), 120)
    {:ok, state, :released} = ExecutionFence.release(state, token, "worker-1", :worker_exit)
    assert {:error, :worker_termination_missing} = FailedAttempt.record(state, token, attrs(), 120)
  end

  test "unconfirmed or future termination cannot become a failed terminal attempt" do
    {state, token} = released()
    assert {:error, :ownership_unreconciled} = FailedAttempt.record(state, token, attrs(), 120)
    {future, token} = confirmed(200)
    assert {:error, :termination_not_already_confirmed} = FailedAttempt.record(future, token, attrs(), 120)
  end

  test "revalidates stored termination evidence instead of trusting the confirmation flag" do
    {state, token} = confirmed()
    lease = put_in(state.executions[@issue].leases["worker-1"], [:termination_evidence, :process_id], "wrong-process")
    tampered = state |> put_in([:executions, @issue, :leases, "worker-1"], lease) |> put_in([:sessions, "worker-1"], lease)
    assert {:error, _} = FailedAttempt.record(tampered, token, attrs(), 120)
  end

  test "an active reviewer prevents a failed attempt transition" do
    {state, token} = confirmed()
    {:ok, state, :registered} = ExecutionFence.register(state, token, :reviewer, session("reviewer-1"), 120)
    assert {:error, :lease_not_released} = FailedAttempt.record(state, token, attrs(), 130)
    {:ok, state, :released} = ExecutionFence.release(state, token, "reviewer-1", :orchestrator_stop)
    assert {:error, :ownership_unreconciled} = FailedAttempt.record(state, token, attrs(), 130)
    {:ok, state, :confirmed} = ExecutionFence.confirm_termination(state, token, "reviewer-1", evidence("reviewer-1", 130), 130)
    assert {:ok, _, :fenced} = FailedAttempt.record(state, token, attrs(), 140)
  end

  @tag :tmp_dir
  test "old terminal snapshots keep their shape and failed snapshots retain evidence across restart", %{tmp_dir: tmp_dir} do
    {state, token} = confirmed()
    {:ok, done, :fenced} = ExecutionFence.fence(state, token, %{terminal_state: "Done", accepted_head: @head}, 120)
    old_path = Path.join(tmp_dir, "ordinary.json")
    assert :ok = Persistence.save(old_path, done)
    assert {:ok, loaded_done} = Persistence.load(old_path)
    assert loaded_done.executions[@issue].terminal == done.executions[@issue].terminal
    refute Map.has_key?(loaded_done.executions[@issue].terminal, :failure_evidence_ref)

    {:ok, failed, :fenced} = FailedAttempt.record(state, token, attrs(), 120)
    path = Path.join(tmp_dir, "failed.json")
    assert :ok = Persistence.save(path, failed)
    assert {:ok, loaded} = Persistence.load(path)
    assert loaded.executions[@issue].terminal == failed.executions[@issue].terminal

    assert loaded.executions[@issue].leases["worker-1"].termination_evidence ==
             failed.executions[@issue].leases["worker-1"].termination_evidence

    assert {:ok, restarted} = ExecutionFence.mark_unreconciled_after_restart(loaded)
    assert {:ok, ^restarted, :already_fenced} = FailedAttempt.record(restarted, token, attrs(), 130)
  end

  defp attrs, do: %{accepted_head: @head, failure_evidence_ref: @failure_ref}
  defp admission, do: %{issue_id: @issue, repository: @repository, branch: @branch, worktree: @worktree}

  defp session(id) do
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
      head: @head,
      last_heartbeat_at: 100
    }
  end

  defp evidence(id, now) do
    %{
      session_id: id,
      process_id: "process-#{id}",
      process_tree: :terminated,
      evidence_ref: @termination_ref,
      observed_at_ms: now
    }
  end

  defp released do
    {:ok, state, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)
    {:ok, state, :registered} = ExecutionFence.register(state, token, :worker, session("worker-1"), 100)
    {:ok, state, :released} = ExecutionFence.release(state, token, "worker-1", :orchestrator_stop)
    {state, token}
  end

  defp confirmed(now \\ 110) do
    {state, token} = released()
    {:ok, state, :confirmed} = ExecutionFence.confirm_termination(state, token, "worker-1", evidence("worker-1", now), now)
    {state, token}
  end
end
