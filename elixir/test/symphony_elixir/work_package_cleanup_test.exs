defmodule SymphonyElixir.WorkPackageCleanupTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{ExecutionFence, WorkPackageCleanup}

  @issue_id "HGS-350"
  @repository "hypergridau/symphony"

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-work-package-cleanup-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    archive_root = Path.join(root, "archives")
    File.mkdir_p!(workspace)

    git!(workspace, ["init"])
    git!(workspace, ["config", "user.email", "symphony-tests@example.test"])
    git!(workspace, ["config", "user.name", "Symphony tests"])
    File.write!(Path.join(workspace, "tracked.txt"), "before\n")
    git!(workspace, ["add", "tracked.txt"])
    git!(workspace, ["commit", "-m", "initial"])

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root, workspace: workspace, archive_root: archive_root}
  end

  test "archives dirty state and open PR candidates outside the workspace", context do
    File.write!(Path.join(context.workspace, "tracked.txt"), "after\n")
    File.write!(Path.join(context.workspace, "untracked.txt"), "recover me\n")
    head = git!(context.workspace, ["rev-parse", "HEAD"]) |> String.trim()
    {fence, token} = admitted_fence(context.workspace)
    state = %{execution_fence: fence}

    assert {:ok, evidence_ref} =
             WorkPackageCleanup.prepare(
               state,
               token,
               head,
               %{workspace_path: context.workspace, worker_host: nil},
               archive_root: context.archive_root,
               command_runner: command_runner()
             )

    archive_dir = archive_dir(context.archive_root, @issue_id, 1, "codex/hgs-350", head)
    assert {:ok, manifest_json} = File.read(Path.join(archive_dir, "manifest.json"))
    assert {:ok, manifest} = Jason.decode(manifest_json)
    assert manifest["evidence_ref"] == evidence_ref
    assert String.contains?(manifest["git"]["status"], "tracked.txt")
    assert String.contains?(manifest["git"]["status"], "untracked.txt")
    assert [%{"number" => 350, "headRefName" => "codex/hgs-350"}] = manifest["open_pull_requests"]
    assert File.exists?(Path.join(archive_dir, "workspace/untracked.txt"))
    assert File.exists?(Path.join(archive_dir, "repository.bundle"))
    refute File.exists?(Path.join(archive_dir, "workspace/.git"))

    assert {:ok, same_evidence_ref} =
             WorkPackageCleanup.prepare(
               state,
               token,
               head,
               %{workspace_path: context.workspace, worker_host: nil},
               archive_root: context.archive_root,
               command_runner: command_runner()
             )

    assert same_evidence_ref == evidence_ref
  end

  test "does not reuse an archive after the workspace content changes", context do
    head = git!(context.workspace, ["rev-parse", "HEAD"]) |> String.trim()
    {fence, token} = admitted_fence(context.workspace)
    state = %{execution_fence: fence}
    opts = [archive_root: context.archive_root, command_runner: command_runner()]

    assert {:ok, _evidence_ref} = WorkPackageCleanup.prepare(state, token, head, %{workspace_path: context.workspace, worker_host: nil}, opts)

    File.write!(Path.join(context.workspace, "untracked.txt"), "first\n")

    assert {:error, :cleanup_archive_state_changed} =
             WorkPackageCleanup.prepare(state, token, head, %{workspace_path: context.workspace, worker_host: nil}, opts)
  end

  test "rebuilds an interrupted archive staging directory", context do
    head = git!(context.workspace, ["rev-parse", "HEAD"]) |> String.trim()
    {fence, token} = admitted_fence(context.workspace)
    opts = [archive_root: context.archive_root, command_runner: command_runner()]
    archive_dir = archive_dir(context.archive_root, @issue_id, 1, "codex/hgs-350", head)
    File.mkdir_p!(Path.join(archive_dir <> ".staging", "workspace"))
    File.write!(Path.join(archive_dir <> ".staging", "workspace/partial.txt"), "partial\n")

    assert {:ok, _evidence_ref} =
             WorkPackageCleanup.prepare(
               %{execution_fence: fence},
               token,
               head,
               %{workspace_path: context.workspace, worker_host: nil},
               opts
             )

    refute File.exists?(archive_dir <> ".staging")
  end

  test "rebuilds a final archive left without its manifest", context do
    head = git!(context.workspace, ["rev-parse", "HEAD"]) |> String.trim()
    {fence, token} = admitted_fence(context.workspace)
    opts = [archive_root: context.archive_root, command_runner: command_runner()]
    archive_dir = archive_dir(context.archive_root, @issue_id, 1, "codex/hgs-350", head)
    File.mkdir_p!(archive_dir)
    File.write!(Path.join(archive_dir, "partial.txt"), "partial\n")

    assert {:ok, _evidence_ref} =
             WorkPackageCleanup.prepare(
               %{execution_fence: fence},
               token,
               head,
               %{workspace_path: context.workspace, worker_host: nil},
               opts
             )

    assert File.exists?(Path.join(archive_dir, "manifest.json"))
  end

  test "archives a linked git worktree with recoverable refs", context do
    source = Path.join(context.root, "source")
    File.rm_rf!(context.workspace)
    File.mkdir_p!(source)
    git!(source, ["init"])
    git!(source, ["config", "user.email", "symphony-tests@example.test"])
    git!(source, ["config", "user.name", "Symphony tests"])
    File.write!(Path.join(source, "tracked.txt"), "source\n")
    git!(source, ["add", "tracked.txt"])
    git!(source, ["commit", "-m", "initial"])
    git!(source, ["worktree", "add", "-b", "codex/hgs-350", context.workspace])

    head = git!(context.workspace, ["rev-parse", "HEAD"]) |> String.trim()
    {fence, token} = admitted_fence(context.workspace)

    assert {:ok, _evidence_ref} =
             WorkPackageCleanup.prepare(
               %{execution_fence: fence},
               token,
               head,
               %{workspace_path: context.workspace, worker_host: nil},
               archive_root: context.archive_root,
               command_runner: command_runner()
             )

    archive_dir = archive_dir(context.archive_root, @issue_id, 1, "codex/hgs-350", head)
    recovery = Path.join(context.root, "recovery")
    git!(context.root, ["clone", Path.join(archive_dir, "repository.bundle"), recovery])
    assert git!(recovery, ["rev-parse", "HEAD"]) |> String.trim() == head
    refute File.exists?(Path.join(archive_dir, "workspace/.git"))
  end

  test "verification rejects a modified archived file", context do
    head = git!(context.workspace, ["rev-parse", "HEAD"]) |> String.trim()
    {fence, token} = admitted_fence(context.workspace)
    state = %{execution_fence: fence}
    opts = [archive_root: context.archive_root, command_runner: command_runner()]

    assert {:ok, evidence_ref} = WorkPackageCleanup.prepare(state, token, head, %{workspace_path: context.workspace, worker_host: nil}, opts)
    {:ok, fence, :released} = ExecutionFence.release(fence, token, "worker:HGS-350:1", :completed)
    {:ok, fence, :fenced} = ExecutionFence.fence(fence, token, %{terminal_state: "Done", accepted_head: head}, 10)
    {:ok, fence, :prepared} = ExecutionFence.prepare_cleanup(fence, token, head, 20, :completed)
    {:ok, fence} = ExecutionFence.record_cleanup_evidence(fence, token, head, evidence_ref, 21)
    state = %{execution_fence: fence}
    archive_dir = archive_dir(context.archive_root, @issue_id, 1, "codex/hgs-350", head)
    File.write!(Path.join(archive_dir, "workspace/tracked.txt"), "tampered\n")
    File.rm_rf!(context.workspace)

    assert {:error, :cleanup_archive_content_mismatch} =
             WorkPackageCleanup.verify(state, token, head, archive_root: context.archive_root)
  end

  test "verification requires the durable evidence and workspace absence", context do
    head = git!(context.workspace, ["rev-parse", "HEAD"]) |> String.trim()
    {fence, token} = admitted_fence(context.workspace)
    state = %{execution_fence: fence}

    assert {:error, :cleanup_evidence_missing} =
             WorkPackageCleanup.verify(state, token, head, archive_root: context.archive_root)

    assert {:ok, evidence_ref} =
             WorkPackageCleanup.prepare(
               state,
               token,
               head,
               %{workspace_path: context.workspace, worker_host: nil},
               archive_root: context.archive_root,
               command_runner: command_runner()
             )

    {:ok, fence, :released} = ExecutionFence.release(fence, token, "worker:HGS-350:1", :completed)
    {:ok, fence, :fenced} = ExecutionFence.fence(fence, token, %{terminal_state: "Done", accepted_head: head}, 10)
    {:ok, fence, :prepared} = ExecutionFence.prepare_cleanup(fence, token, head, 20, :completed)
    {:ok, fence} = ExecutionFence.record_cleanup_evidence(fence, token, head, evidence_ref, 21)
    state = %{execution_fence: fence}

    assert {:error, :cleanup_workspace_still_present} =
             WorkPackageCleanup.verify(state, token, head, archive_root: context.archive_root)

    File.rm_rf!(context.workspace)

    assert {:ok, ^evidence_ref} =
             WorkPackageCleanup.verify(state, token, head, archive_root: context.archive_root)
  end

  test "refuses an archive root inside the active workspace", context do
    head = git!(context.workspace, ["rev-parse", "HEAD"]) |> String.trim()
    {fence, token} = admitted_fence(context.workspace)

    assert {:error, :cleanup_archive_inside_workspace} =
             WorkPackageCleanup.prepare(
               %{execution_fence: fence},
               token,
               head,
               %{workspace_path: context.workspace, worker_host: nil},
               archive_root: Path.join(context.workspace, "archives"),
               command_runner: command_runner()
             )
  end

  defp admitted_fence(workspace) do
    admission = %{
      issue_id: @issue_id,
      repository: @repository,
      branch: "codex/hgs-350",
      worktree: workspace,
      worker_host: nil
    }

    {:ok, fence, token} = ExecutionFence.admit(ExecutionFence.new(), admission, 0)

    session =
      Map.merge(admission, %{
        generation: 1,
        role: :worker,
        session_id: "worker:HGS-350:1",
        process_id: "worker:HGS-350:1",
        linear_state: "In Progress",
        pr_state: "OPEN",
        head: "unobserved",
        last_heartbeat_at: 0
      })

    {:ok, fence, :registered} = ExecutionFence.register(fence, token, :worker, session, 0)
    {fence, token}
  end

  defp command_runner do
    fn
      "gh", _args, _opts ->
        {Jason.encode!([%{"number" => 350, "url" => "https://github.example/pr/350", "reviewDecision" => "REVIEW_REQUIRED", "isDraft" => false, "headRefName" => "codex/hgs-350"}]), 0}

      executable, args, opts ->
        System.cmd(executable, args, opts)
    end
  end

  defp git!(workspace, args) do
    {output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    output
  end

  defp archive_dir(root, issue, generation, branch, head) do
    digest =
      :crypto.hash(:sha256, Enum.join([issue, Integer.to_string(generation), branch, head], "\u0000"))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    Path.join(root, "cleanup-" <> digest)
  end
end
