defmodule SymphonyElixir.LegacyWorkPackageCleanupTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{ExecutionFence, WorkPackageCleanup}

  test "reuses and verifies the original v1 manifest without rewriting its evidence" do
    fixture = __DIR__ |> Path.join("../fixtures/cleanup_archive_v1.json") |> File.read!() |> Jason.decode!()
    manifest_bytes = Base.decode64!(fixture["manifest_base64"])
    manifest = Jason.decode!(manifest_bytes)
    root = Path.join(System.tmp_dir!(), "symphony-legacy-archive-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}")
    File.mkdir!(root)
    on_exit(fn -> assert {:ok, _} = File.rm_rf(root) end)
    bundle = Path.join(root, "repository.bundle")
    File.write!(bundle, Base.decode64!(fixture["bundle_base64"]))
    workspace = Path.join(root, "workspace")
    git!(root, ["clone", bundle, workspace])
    git!(workspace, ["config", "core.autocrlf", "false"])
    archive_root = Path.join(root, "archives")
    key = Enum.join([manifest["issue_id"], "1", manifest["branch"], manifest["expected_head"]], "\u0000")
    hash = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> binary_part(0, 32)
    archive = Path.join(archive_root, "cleanup-" <> hash)
    archived_workspace = Path.join(archive, "workspace")
    File.mkdir_p!(archived_workspace)

    for directory <- fixture["directories"], path <- [workspace, archived_workspace] do
      File.mkdir!(Path.join(path, directory))
    end

    for entry <- manifest["content"]["workspace_files"], path <- [workspace, archived_workspace] do
      file = Path.join(path, entry["path"])
      File.write!(file, Base.decode64!(fixture["files"][entry["path"]]))
      File.chmod!(file, entry["mode"])
    end

    File.write!(Path.join(archive, "repository.bundle"), File.read!(bundle))
    File.write!(Path.join(archive, "manifest.json"), manifest_bytes)

    admission = %{
      issue_id: manifest["issue_id"],
      repository: manifest["repository_ref"],
      branch: manifest["branch"],
      worktree: workspace,
      worker_host: nil
    }

    {:ok, fence, token} = ExecutionFence.admit(ExecutionFence.new(), admission, 0)
    head = manifest["expected_head"]
    evidence = manifest["evidence_ref"]
    opts = [archive_root: archive_root, command_runner: &command/3]
    entry = %{workspace_path: workspace, worker_host: nil}
    assert {:ok, ^evidence} = WorkPackageCleanup.prepare(%{execution_fence: fence}, token, head, entry, opts)
    assert File.read!(Path.join(archive, "manifest.json")) == manifest_bytes
    {:ok, fence, :fenced} = ExecutionFence.fence(fence, token, %{terminal_state: "Done", accepted_head: head}, 10)
    {:ok, fence, :prepared} = ExecutionFence.prepare_cleanup(fence, token, head, 20, :completed)
    {:ok, fence} = ExecutionFence.record_cleanup_evidence(fence, token, head, evidence, 21)
    assert {:ok, _} = File.rm_rf(workspace)
    assert {:ok, ^evidence} = WorkPackageCleanup.verify(%{execution_fence: fence}, token, head, opts)
    assert File.read!(Path.join(archive, "manifest.json")) == manifest_bytes
  end

  defp command("gh", _args, _opts), do: {"[]", 0}
  defp command(executable, args, opts), do: System.cmd(executable, args, opts)

  defp git!(workspace, args) do
    {output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    output
  end
end
