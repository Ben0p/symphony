defmodule SymphonyElixir.ManagedCheckoutTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ManagedCheckout

  setup do
    root = Path.join(System.tmp_dir!(), "managed-checkout-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    source = Path.join(root, "source")
    workspace = Path.join(root, "MC-1")
    File.mkdir!(source)
    git(source, ["init", "-b", "main"])
    git(source, ["config", "user.name", "Checkout test"])
    git(source, ["config", "user.email", "checkout@example.invalid"])
    File.write!(Path.join(source, "README.md"), "fixture\n")
    git(source, ["add", "README.md"])
    git(source, ["commit", "-m", "initial"])
    git(root, ["clone", "--no-local", source, workspace])
    git(workspace, ["remote", "set-url", "origin", "https://github.com/example/repository.git"])
    base = git(workspace, ["rev-parse", "HEAD"])
    identity = %{issue_id: "issue-1", generation: 1, session_id: "worker:issue-1:1", repository: "example/repository", worktree: workspace, branch: "codex/MC-1"}
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, identity: identity, base: base}
  end

  test "fresh real clone gets the fenced task branch and same-generation dirty reuse", ctx do
    assert {:ok, %{head: head, branch: "codex/MC-1"}} =
             ManagedCheckout.prepare(ctx.workspace, ctx.identity, true)

    assert head == ctx.base
    File.write!(Path.join(ctx.workspace, "README.md"), "legitimate work\n")
    assert {:ok, %{head: ^head}} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, false)
    assert git(ctx.workspace, ["branch", "--show-current"]) == "codex/MC-1"
  end

  test "a legitimate commit may advance the marked head", ctx do
    assert {:ok, _} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, true)
    git(ctx.workspace, ["config", "user.name", "Checkout test"])
    git(ctx.workspace, ["config", "user.email", "checkout@example.invalid"])
    File.write!(Path.join(ctx.workspace, "README.md"), "accepted source work\n")
    git(ctx.workspace, ["add", "README.md"])
    git(ctx.workspace, ["commit", "-m", "work"])
    assert {:ok, %{head: head}} = ManagedCheckout.verify(ctx.workspace, ctx.identity)
    refute head == ctx.base
  end

  test "unmarked existing workspace is never silently repaired", ctx do
    assert {:error, _} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, false)
    assert git(ctx.workspace, ["branch", "--show-current"]) == "main"
    refute File.exists?(marker(ctx))
  end

  test "dirty fresh clone is retained on its original branch", ctx do
    File.write!(Path.join(ctx.workspace, "unique.txt"), "preserve me")
    assert {:error, _} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, true)
    assert File.read!(Path.join(ctx.workspace, "unique.txt")) == "preserve me"
    assert git(ctx.workspace, ["branch", "--show-current"]) == "main"
  end

  test "invalid branch representations never mutate main", ctx do
    for branch <- ["main", "master", "HEAD", "@{-1}", "refs/heads/x", "-option", "a b", "a\nb", "a..b", "a//b"] do
      assert {:error, _} = ManagedCheckout.prepare(ctx.workspace, %{ctx.identity | branch: branch}, true)
      assert git(ctx.workspace, ["branch", "--show-current"]) == "main"
    end

    refute File.exists?(marker(ctx))
  end

  test "captured remote task ref collision is preserved", ctx do
    git(ctx.workspace, ["update-ref", "refs/remotes/origin/codex/MC-1", ctx.base])
    assert {:error, :managed_checkout_branch_exists} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, true)
    assert git(ctx.workspace, ["rev-parse", "refs/remotes/origin/codex/MC-1"]) == ctx.base
    assert git(ctx.workspace, ["branch", "--show-current"]) == "main"
  end

  test "a local branch collision is preserved", ctx do
    git(ctx.workspace, ["branch", ctx.identity.branch, ctx.base])
    assert {:error, :managed_checkout_branch_exists} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, true)
    assert git(ctx.workspace, ["branch", "--show-current"]) == "main"
    assert git(ctx.workspace, ["rev-parse", "refs/heads/#{ctx.identity.branch}"]) == ctx.base
  end

  test "a single-branch clone contract cannot attest remote branch absence", ctx do
    git(ctx.workspace, ["config", "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/main"])
    assert {:error, _} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, true)
    assert git(ctx.workspace, ["branch", "--show-current"]) == "main"
    refute File.exists?(marker(ctx))
  end

  test "origin whitespace is rejected instead of normalized into a matching repository", ctx do
    git(ctx.workspace, ["config", "remote.origin.url", " https://github.com/example/repository.git "])
    assert {:error, :managed_checkout_repository_mismatch} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, true)
    assert git(ctx.workspace, ["branch", "--show-current"]) == "main"
  end

  test "authority lost after branch creation leaves an unmarked held checkout", ctx do
    Process.put(:checkout_marker_guard, 0)

    guard = fn ->
      count = Process.get(:checkout_marker_guard) + 1
      Process.put(:checkout_marker_guard, count)
      if count < 3, do: :ok, else: {:error, :terminal_fenced}
    end

    assert {:error, :terminal_fenced} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, true, guard)
    assert git(ctx.workspace, ["branch", "--show-current"]) == ctx.identity.branch
    refute File.exists?(marker(ctx))
    assert {:error, _} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, false)
  end

  test "wrong generation, session and issue cannot reuse a valid marker", ctx do
    assert {:ok, _} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, true)

    for changed <- [
          %{ctx.identity | generation: 2},
          %{ctx.identity | session_id: "worker:other:1"},
          %{ctx.identity | issue_id: "other"}
        ] do
      assert {:error, _} = ManagedCheckout.verify(ctx.workspace, changed)
    end

    assert {:ok, _} = ManagedCheckout.verify(ctx.workspace, ctx.identity)
  end

  test "branch change and detached head are rejected without repair", ctx do
    assert {:ok, _} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, true)
    git(ctx.workspace, ["switch", "main"])
    assert {:error, _} = ManagedCheckout.verify(ctx.workspace, ctx.identity)
    assert git(ctx.workspace, ["branch", "--show-current"]) == "main"
    git(ctx.workspace, ["checkout", "--detach", ctx.base])
    assert {:error, _} = ManagedCheckout.verify(ctx.workspace, ctx.identity)
    assert git(ctx.workspace, ["branch", "--show-current"]) == ""
  end

  test "wrong origin and changed Git worktree root fail closed", ctx do
    assert {:ok, _} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, true)
    git(ctx.workspace, ["remote", "set-url", "origin", "https://github.com/example/other.git"])
    assert {:error, _} = ManagedCheckout.verify(ctx.workspace, ctx.identity)
    git(ctx.workspace, ["remote", "set-url", "origin", "https://github.com/example/repository.git"])
    git(ctx.workspace, ["config", "core.worktree", ctx.root])
    assert {:error, _} = ManagedCheckout.verify(ctx.workspace, ctx.identity)
  end

  test "partial and oversized markers remain present and reject reuse", ctx do
    assert {:ok, _} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, true)

    for bytes <- ["{", String.duplicate("x", 4_097)] do
      File.write!(marker(ctx), bytes)
      assert {:error, _} = ManagedCheckout.verify(ctx.workspace, ctx.identity)
      assert File.read!(marker(ctx)) == bytes
    end
  end

  test "symlink workspace aliases and marker links are rejected", ctx do
    assert {:ok, _} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, true)
    alias_path = Path.join(ctx.root, "alias")
    File.ln_s!(ctx.workspace, alias_path)
    assert {:error, _} = ManagedCheckout.verify(alias_path, %{ctx.identity | worktree: alias_path})
    saved = Path.join(ctx.root, "saved-marker.json")
    File.rename!(marker(ctx), saved)
    File.ln_s!(saved, marker(ctx))
    assert {:error, _} = ManagedCheckout.verify(ctx.workspace, ctx.identity)
    assert File.exists?(saved)
  end

  test "Git repository-redirecting environment cannot alter the inspected repository", ctx do
    assert {:ok, _} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, true)
    old = System.get_env("GIT_DIR")

    try do
      System.put_env("GIT_DIR", Path.join(ctx.root, "source/.git"))
      assert {:ok, %{branch: "codex/MC-1"}} = ManagedCheckout.verify(ctx.workspace, ctx.identity)
    after
      if old, do: System.put_env("GIT_DIR", old), else: System.delete_env("GIT_DIR")
    end
  end

  test "guard loss after freshness probes prevents branch mutation", ctx do
    Process.put(:checkout_guard_count, 0)

    guard = fn ->
      count = Process.get(:checkout_guard_count) + 1
      Process.put(:checkout_guard_count, count)
      if count == 1, do: :ok, else: {:error, :terminal_fenced}
    end

    assert {:error, :terminal_fenced} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, true, guard)
    assert git(ctx.workspace, ["branch", "--show-current"]) == "main"
    refute File.exists?(marker(ctx))
  end

  test "duplicate marker fields reject even when their values agree", ctx do
    assert {:ok, _} = ManagedCheckout.prepare(ctx.workspace, ctx.identity, true)
    original = File.read!(marker(ctx))
    duplicate = "{\"version\":1," <> String.trim_leading(original, "{")
    File.write!(marker(ctx), duplicate)
    assert {:error, _} = ManagedCheckout.verify(ctx.workspace, ctx.identity)
    assert File.read!(marker(ctx)) == duplicate
  end

  defp marker(ctx), do: Path.join(ctx.workspace, ".git/symphony-execution.json")

  defp git(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end
end
