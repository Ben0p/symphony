defmodule SymphonyElixir.ManagedCheckoutWorkspaceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Issue

  setup do
    root = Path.join(Path.dirname(Workflow.workflow_file_path()), "managed-workspaces")
    File.mkdir_p!(root)
    issue = %Issue{id: "managed-checkout-issue", identifier: "MC-1", title: "checkout ownership"}

    identity = %{
      issue_id: issue.id,
      generation: 1,
      session_id: "worker:#{issue.id}:1",
      repository: "example/repository",
      branch: "codex/MC-1",
      worktree: Path.join(root, issue.identifier)
    }

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
    %{root: root, issue: issue, identity: identity}
  end

  test "a non-directory collision survives managed preparation", %{issue: issue, identity: identity} do
    File.write!(identity.worktree, "unique retained bytes")

    assert {:error, :managed_checkout_path_collision} =
             Workspace.create_for_execution(issue, identity, nil, fn -> :ok end)

    assert File.read!(identity.worktree) == "unique retained bytes"
  end

  test "a failed clone hook retains its partial work", %{root: root, issue: issue, identity: identity} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      hook_after_create: "printf 'partial clone evidence' > retained.txt; exit 23"
    )

    assert {:error, _} = Workspace.create_for_execution(issue, identity, nil, fn -> :ok end)
    assert File.read!(Path.join(identity.worktree, "retained.txt")) == "partial clone evidence"
  end

  test "stale authority prevents creating a managed directory", %{issue: issue, identity: identity} do
    assert {:error, :terminal_fenced} =
             Workspace.create_for_execution(issue, identity, nil, fn -> {:error, :terminal_fenced} end)

    refute File.exists?(identity.worktree)
  end

  test "authority lost during the clone hook prevents branch preparation", %{root: root, issue: issue, identity: identity} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      hook_after_create: "printf 'preserve failed attempt' > retained.txt"
    )

    Process.put(:managed_checkout_guard_calls, 0)

    guard = fn ->
      count = Process.get(:managed_checkout_guard_calls) + 1
      Process.put(:managed_checkout_guard_calls, count)
      if count < 3, do: :ok, else: {:error, :terminal_fenced}
    end

    assert {:error, :terminal_fenced} = Workspace.create_for_execution(issue, identity, nil, guard)
    assert File.read!(Path.join(identity.worktree, "retained.txt")) == "preserve failed attempt"
    refute File.exists?(Path.join(identity.worktree, ".git/symphony-execution.json"))
  end

  test "remote managed preparation fails before the local path is touched", %{issue: issue, identity: identity} do
    assert {:error, :unsupported_managed_checkout_host_or_identity} =
             Workspace.create_for_execution(issue, identity, "unqualified-host", fn -> :ok end)

    refute File.exists?(identity.worktree)
  end
end
