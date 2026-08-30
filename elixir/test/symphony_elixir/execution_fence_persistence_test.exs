defmodule SymphonyElixir.ExecutionFencePersistenceTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ExecutionFence
  alias SymphonyElixir.ExecutionFence.Persistence

  @issue "HGS-294"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-execution-fence-#{System.unique_integer([:positive])}"
      )

    path = Path.join(root, "state.json")
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, path: path}
  end

  test "persists and rehydrates the complete generation and lease registry", %{path: path} do
    {:ok, state, token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)

    {:ok, state, :registered} =
      ExecutionFence.register(state, token, :worker, session("worker-1"), 100)

    {:ok, state, :registered} =
      ExecutionFence.register(state, token, :reviewer, session("reviewer-1"), 100)

    assert :ok = Persistence.save(path, state)
    assert {:ok, restored} = Persistence.load(path)
    assert restored == state
    assert {:ok, restored} = ExecutionFence.mark_unreconciled_after_restart(restored)
    assert restored.executions[@issue].ownership == :unknown
    assert restored.executions[@issue].leases["worker-1"].status == :active
    assert restored.executions[@issue].leases["reviewer-1"].status == :active
  end

  test "a malformed durable snapshot fails closed", %{path: path} do
    File.write!(path, ~s({"schema_version":1,"executions":[],"sessions":{},"history":[]}))

    assert {:error, {:invalid_snapshot, _reason}} = Persistence.load(path)
  end

  test "save creates the parent directory and replaces an existing snapshot", %{path: path} do
    {:ok, state, _token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)
    assert :ok = Persistence.save(path, state)

    {:ok, next_state, _next_token} = ExecutionFence.admit(state, admission("next"), 200)
    assert :ok = Persistence.save(path, next_state)
    assert {:ok, restored} = Persistence.load(path)
    assert Map.has_key?(restored.executions, "next")
  end

  test "recovers a valid snapshot left beside a missing primary file", %{path: path} do
    {:ok, state, _token} = ExecutionFence.admit(ExecutionFence.new(), admission(), 100)
    assert :ok = Persistence.save(path, state)

    recovery_path = "#{path}.previous-recovery"
    assert :ok = File.rename(path, recovery_path)

    assert {:ok, ^state} = Persistence.load(path)
  end

  defp admission(issue_id \\ @issue) do
    %{
      issue_id: issue_id,
      repository: "openai/symphony",
      branch: "codex/#{String.downcase(issue_id)}",
      worktree: "C:/code/hypergrid.au/_worktrees/#{String.downcase(issue_id)}"
    }
  end

  defp session(session_id) do
    Map.merge(admission(), %{
      generation: 1,
      role: :worker,
      session_id: session_id,
      process_id: "process-#{session_id}",
      linear_state: "In Progress",
      pr_state: "OPEN",
      head: "abc123",
      last_heartbeat_at: 100
    })
  end
end
