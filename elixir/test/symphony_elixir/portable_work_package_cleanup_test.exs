defmodule SymphonyElixir.PortableWorkPackageCleanupTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{ExecutionFence, WorkPackageCleanup}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-portable-cleanup-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    git!(workspace, ["init", "-b", "codex/hgs-441"])
    git!(workspace, ["config", "user.email", "symphony-tests@example.test"])
    git!(workspace, ["config", "user.name", "Symphony tests"])
    git!(workspace, ["config", "core.autocrlf", "false"])
    File.write!(Path.join(workspace, "tracked.txt"), "committed\n")
    git!(workspace, ["add", "."])
    git!(workspace, ["commit", "-m", "initial"])
    head = git!(workspace, ["rev-parse", "HEAD"]) |> String.trim()
    admission = %{issue_id: "HGS-441", repository: "Ben0p/symphony", branch: "codex/hgs-441", worktree: workspace, worker_host: nil}
    {:ok, fence, token} = ExecutionFence.admit(ExecutionFence.new(), admission, 0)
    opts = [archive_root: Path.join(root, "archives"), command_runner: &command/3]
    on_exit(fn -> assert {:ok, _} = File.rm_rf(root) end)
    {:ok, root: root, workspace: workspace, head: head, state: %{execution_fence: fence}, token: token, opts: opts}
  end

  test "preserves nested directory links as metadata without traversing their targets", context do
    shared = Path.join(context.root, "shared")
    canonical = Path.join(context.root, "canonical")
    File.mkdir_p!(shared)
    File.mkdir_p!(canonical)
    File.mkdir_p!(Path.join(context.workspace, "packages/app/empty"))
    File.write!(Path.join(shared, "shared-marker.txt"), "shared exact\n")
    File.write!(Path.join(canonical, "canonical-marker.txt"), "canonical exact\n")
    directory_link!(canonical, Path.join(shared, "canonical"))
    link = Path.join(context.workspace, "packages/app/node_modules")
    directory_link!(shared, link)
    File.write!(Path.join(context.workspace, "tracked.txt"), "staged\n")
    git!(context.workspace, ["add", "tracked.txt"])
    File.write!(Path.join(context.workspace, "tracked.txt"), "unstaged\n")
    File.write!(Path.join(context.workspace, "untracked.bin"), <<0, 255, 13, 10>>)

    assert {:ok, evidence} = prepare(context)
    archive = archive!(context)
    manifest = manifest!(archive)
    assert manifest["archive_version"] == 2
    assert File.read!(Path.join(archive, "workspace/tracked.txt")) == "unstaged\n"
    assert File.read!(Path.join(archive, "workspace/untracked.bin")) == <<0, 255, 13, 10>>
    assert File.dir?(Path.join(archive, "workspace/packages/app/empty"))
    assert {:error, :enoent} = File.lstat(Path.join(archive, "workspace/packages/app/node_modules"))
    {:ok, target} = File.read_link(link)

    assert Enum.filter(manifest["content"]["workspace_files"], &(&1["type"] == "symlink")) ==
             [%{"path" => "packages/app/node_modules", "type" => "symlink", "target" => target, "size" => byte_size(target), "sha256" => digest(target)}]

    refute Enum.any?(manifest["content"]["workspace_files"], &String.contains?(&1["path"], "marker.txt"))
    assert manifest["git"]["staged_diff"] =~ "+staged"
    assert manifest["git"]["unstaged_diff"] =~ "+unstaged"
    recovery = Path.join(context.root, "recovery")
    git!(context.root, ["clone", Path.join(archive, "repository.bundle"), recovery])
    assert String.trim(git!(recovery, ["rev-parse", "HEAD"])) == context.head
    assert git!(recovery, ["show", "HEAD:tracked.txt"]) == "committed\n"
    git!(recovery, ["config", "core.autocrlf", "false"])
    staged_patch = Path.join(context.root, "staged.patch")
    File.write!(staged_patch, manifest["git"]["staged_diff"] <> "\n")
    git!(recovery, ["apply", "--cached", staged_patch])

    for file <- ["tracked.txt", "untracked.bin"] do
      File.write!(Path.join(recovery, file), File.read!(Path.join([archive, "workspace", file])))
    end

    File.mkdir_p!(Path.join(recovery, "packages/app/empty"))
    directory_link!(target, Path.join(recovery, "packages/app/node_modules"))
    assert String.trim_trailing(git!(recovery, ["diff", "--cached", "--binary"]), "\n") == manifest["git"]["staged_diff"]
    assert String.trim_trailing(git!(recovery, ["diff", "--binary", "HEAD"]), "\n") == manifest["git"]["unstaged_diff"]
    assert String.trim_trailing(git!(recovery, ["status", "--porcelain=v1", "--untracked-files=all"]), "\n") == manifest["git"]["status"]
    assert {:ok, ^evidence} = prepare(context)

    assert {:ok, _} = File.rm_rf(context.workspace)
    assert File.read!(Path.join(shared, "shared-marker.txt")) == "shared exact\n"
    assert File.read!(Path.join(canonical, "canonical-marker.txt")) == "canonical exact\n"

    verified = receipt_state(context, evidence)
    assert {:ok, ^evidence} = WorkPackageCleanup.verify(verified, context.token, context.head, context.opts)

    # Explicit reconstruction is separate from verification and touches only this fixture.
    restored_link = Path.join(context.root, "restored-link")
    directory_link!(target, restored_link)
    assert File.read_link!(restored_link) == target
    assert File.read!(Path.join(restored_link, "shared-marker.txt")) == "shared exact\n"
  end

  test "rebuilds interrupted staging without following its nested directory links", context do
    staging = expected_archive(context) <> ".staging"
    external = Path.join(context.root, "external")
    File.mkdir_p!(Path.join(staging, "workspace/nested"))
    File.mkdir_p!(external)
    File.write!(Path.join(external, "marker.txt"), "external exact\n")
    directory_link!(external, Path.join(staging, "workspace/nested/link"))
    assert {:ok, _evidence} = prepare(context)
    assert File.read!(Path.join(external, "marker.txt")) == "external exact\n"
    refute File.exists?(staging)
  end

  test "refuses a source change made while the repository bundle is produced", context do
    runner = fn executable, args, opts ->
      if executable == "git" and Enum.take(args, 2) == ["bundle", "create"] do
        File.write!(Path.join(context.workspace, "untracked-after-copy.txt"), "late mutation\n")
      end

      command(executable, args, opts)
    end

    context = %{context | opts: Keyword.put(context.opts, :command_runner, runner)}
    assert {:error, {:cleanup_archive_build_failed, :cleanup_archive_state_changed}} = prepare(context)
    assert File.read!(Path.join(context.workspace, "untracked-after-copy.txt")) == "late mutation\n"
    refute File.exists?(expected_archive(context))
  end

  test "refuses changed link metadata even when its own target hash is updated", context do
    external = Path.join(context.root, "external")
    File.mkdir_p!(external)
    directory_link!(external, Path.join(context.workspace, "link"))
    assert {:ok, evidence} = prepare(context)
    archive = archive!(context)
    manifest = manifest!(archive)

    entries =
      Enum.map(manifest["content"]["workspace_files"], fn
        %{"type" => "symlink"} = entry -> Map.merge(entry, %{"target" => "forged", "size" => 6, "sha256" => digest("forged")})
        entry -> entry
      end)

    File.write!(Path.join(archive, "manifest.json"), Jason.encode!(put_in(manifest, ["content", "workspace_files"], entries)))
    assert {:ok, _} = File.rm_rf(context.workspace)
    assert {:error, :cleanup_manifest_mismatch} = WorkPackageCleanup.verify(receipt_state(context, evidence), context.token, context.head, context.opts)
  end

  defp receipt_state(context, evidence) do
    {:ok, fence, :fenced} = ExecutionFence.fence(context.state.execution_fence, context.token, %{terminal_state: "Done", accepted_head: context.head}, 10)
    {:ok, fence, :prepared} = ExecutionFence.prepare_cleanup(fence, context.token, context.head, 20, :completed)
    {:ok, fence} = ExecutionFence.record_cleanup_evidence(fence, context.token, context.head, evidence, 21)
    %{execution_fence: fence}
  end

  defp expected_archive(context) do
    key = Enum.join(["HGS-441", Integer.to_string(context.token.generation), "codex/hgs-441", context.head], "\u0000")
    Path.join(Keyword.fetch!(context.opts, :archive_root), "cleanup-" <> binary_part(digest(key), 0, 32))
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  test "rejects an obsolete generation before running a command", context do
    context = %{context | token: %{context.token | generation: context.token.generation + 1}, opts: Keyword.put(context.opts, :command_runner, fn _, _, _ -> flunk("stale generation reached I/O") end)}
    assert {:error, :cleanup_target_missing} = prepare(context)
    refute File.exists?(Keyword.fetch!(context.opts, :archive_root))
  end

  test "rejects a workspace override outside the execution identity", context do
    another = Path.join(context.root, "another-workspace")
    opts = Keyword.put(context.opts, :command_runner, fn _, _, _ -> flunk("wrong workspace reached I/O") end)

    assert {:error, :cleanup_target_missing} =
             WorkPackageCleanup.prepare(context.state, context.token, context.head, %{workspace_path: another, worker_host: nil}, opts)

    refute File.exists?(Keyword.fetch!(opts, :archive_root))
  end

  defp prepare(context) do
    WorkPackageCleanup.prepare(context.state, context.token, context.head, %{workspace_path: context.workspace, worker_host: nil}, context.opts)
  end

  defp archive!(context) do
    [name] = File.ls!(Keyword.fetch!(context.opts, :archive_root))
    Path.join(Keyword.fetch!(context.opts, :archive_root), name)
  end

  defp manifest!(archive), do: archive |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

  defp command("gh", _args, _opts), do: {"[]", 0}
  defp command(executable, args, opts), do: System.cmd(executable, args, opts)

  defp git!(workspace, args) do
    {output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    output
  end

  defp directory_link!(target, link) do
    case :os.type() do
      {:win32, _} ->
        assert {_output, 0} = System.cmd("cmd.exe", ["/d", "/s", "/c", "mklink", "/J", String.replace(link, "/", "\\"), String.replace(target, "/", "\\")], stderr_to_stdout: true)

      _ ->
        assert :ok = File.ln_s(target, link)
    end

    on_exit(fn ->
      result = if match?({:win32, _}, :os.type()), do: File.rmdir(link), else: File.rm(link)
      assert result in [:ok, {:error, :enoent}]
    end)
  end
end
