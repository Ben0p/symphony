defmodule SymphonyElixir.ManagedCheckoutProgressTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ManagedCheckout
  alias SymphonyElixir.ManagedCheckout.Progress

  setup do
    root = Path.join(System.tmp_dir!(), "checkout-progress-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    git(root, ["init", "-b", "main"])
    git(root, ["config", "user.name", "Progress fixture"])
    git(root, ["config", "user.email", "progress@example.invalid"])
    git(root, ["remote", "add", "origin", "https://github.com/example/repository.git"])
    File.write!(Path.join(root, "README.md"), "initial\n")
    git(root, ["add", "README.md"])
    git(root, ["commit", "-m", "initial"])
    git(root, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    identity = %{issue_id: "progress-1", generation: 1, session_id: "worker:progress-1:1", repository: "example/repository", worktree: root, branch: "codex/progress-1"}
    assert {:ok, observed} = ManagedCheckout.prepare(root, identity, true)

    opts =
      Progress.attach(root,
        execution_checkout: identity,
        execution_checkout_checkpoint: fn checkpoint ->
          send(self(), {:checkpoint, checkpoint})
          :ok
        end
      )

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, identity: identity, opts: opts, observed: observed}
  end

  test "real changed descendants earn one checkpoint and empty commits only advance the cursor", ctx do
    assert :ok = Progress.observe(ctx.opts, ctx.observed)
    assert_receive {:checkpoint, %{kind: :baseline, sequence: 0, previous_head: nil}}
    assert :ok = Progress.observe(ctx.opts, ctx.observed)
    refute_received {:checkpoint, _}

    changed = commit(ctx, "useful source\n")
    assert :ok = Progress.observe(ctx.opts, changed)
    assert_receive {:checkpoint, %{kind: :durable, sequence: 1, tree_changed: true, previous_head: previous}}
    assert previous == ctx.observed.head
    git(ctx.root, ["commit", "--allow-empty", "-m", "empty"])
    assert {:ok, empty} = ManagedCheckout.verify(ctx.root, ctx.identity)
    assert :ok = Progress.observe(ctx.opts, empty)
    assert_receive {:checkpoint, %{kind: :observed, sequence: 2, tree_changed: false}}
    assert :ok = Progress.observe(ctx.opts, empty)
    refute_received {:checkpoint, _}
  end

  test "history rewrite latches the exact Git failure even when HEAD later returns", ctx do
    assert :ok = Progress.observe(ctx.opts, ctx.observed)
    changed = commit(ctx, "changed\n")
    assert :ok = Progress.observe(ctx.opts, changed)
    git(ctx.root, ["reset", "--hard", ctx.observed.head])
    assert {:error, {:git_failed, 1}} = Progress.observe(ctx.opts, ctx.observed)
    git(ctx.root, ["reset", "--hard", changed.head])
    assert {:error, {:git_failed, 1}} = Progress.observe(ctx.opts, changed)
    assert {:error, {:git_failed, 1}} = Progress.status(ctx.opts)
  end

  test "an amended commit cannot earn progress from a previously observed HEAD", ctx do
    assert :ok = Progress.observe(ctx.opts, ctx.observed)
    changed = commit(ctx, "changed\n")
    assert :ok = Progress.observe(ctx.opts, changed)
    git(ctx.root, ["commit", "--amend", "-m", "rewritten history"])
    assert {:ok, amended} = ManagedCheckout.verify(ctx.root, ctx.identity)
    refute amended.head == changed.head
    assert {:error, {:git_failed, 1}} = Progress.observe(ctx.opts, amended)
    assert {:error, {:git_failed, 1}} = Progress.observe(ctx.opts, amended)
  end

  test "failed baseline, including nil reason, never retries or becomes progress", ctx do
    for reason <- [nil, :rejected, {:git_process_termination_unconfirmed, :git_timeout_requires_reconciliation}] do
      opts =
        Progress.attach(ctx.root,
          execution_checkout: ctx.identity,
          execution_checkout_checkpoint: fn _ ->
            send(self(), :attempted)
            {:error, reason}
          end
        )

      assert {:error, ^reason} = Progress.observe(opts, ctx.observed)
      assert_receive :attempted
      assert {:error, ^reason} = Progress.observe(opts, ctx.observed)
      assert {:error, ^reason} = Progress.fail(opts, :later)
      refute_received :attempted
      assert :ok = Progress.clear(opts)
    end
  end

  test "foreign process cannot observe or clear an attempt and restart receives only a baseline", ctx do
    assert :ok = Progress.observe(ctx.opts, ctx.observed)
    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:foreign, Progress.observe(ctx.opts, ctx.observed), Progress.clear(ctx.opts)})
      end)

    Task.await(task)
    assert_receive {:foreign, {:error, :progress_owner_mismatch}, {:error, :progress_owner_mismatch}}
    assert :ok = Progress.status(ctx.opts)
    assert :ok = Progress.clear(ctx.opts)
    assert {:error, :missing_progress_cursor} = Progress.observe(ctx.opts, ctx.observed)

    opts =
      Progress.attach(ctx.root,
        execution_checkout: ctx.identity,
        execution_checkout_checkpoint: fn checkpoint ->
          send(self(), {:new, checkpoint})
          :ok
        end
      )

    assert :ok = Progress.observe(opts, ctx.observed)
    assert_receive {:new, %{kind: :baseline, sequence: 0}}
  end

  test "malformed callbacks, identities and verified heads reject while legacy calls stay compatible", ctx do
    for changed <- [%{ctx.observed | head: "not-a-sha"}, %{ctx.observed | branch: "main"}, nil] do
      opts = Progress.attach(ctx.root, execution_checkout: ctx.identity, execution_checkout_checkpoint: fn _ -> :ok end)
      assert {:error, :invalid_verified_checkout} = Progress.observe(opts, changed)
      assert {:error, :invalid_verified_checkout} = Progress.observe(opts, ctx.observed)
    end

    invalid = Progress.attach(ctx.root, execution_checkout: ctx.identity, execution_checkout_checkpoint: false)
    assert {:error, :invalid_execution_checkout_checkpoint} = Progress.status(invalid)
    assert [] == Progress.attach(ctx.root, [])
    assert :ok = Progress.observe([], nil)
    assert :ok = Progress.status(Progress.attach(ctx.root, execution_checkout_checkpoint: fn _ -> :ok end))
  end

  test "external object alternates reject without reading the referenced repository", ctx do
    path = Path.join(ctx.root, ".git/objects/info/alternates")
    File.write!(path, "/outside/objects\n")
    assert {:error, :managed_checkout_repository_mismatch} = ManagedCheckout.verify(ctx.root, ctx.identity)
    assert File.read!(path) == "/outside/objects\n"
  end

  defp commit(ctx, text) do
    File.write!(Path.join(ctx.root, "README.md"), text)
    git(ctx.root, ["add", "README.md"])
    git(ctx.root, ["commit", "-m", "source advancement"])
    assert {:ok, observed} = ManagedCheckout.verify(ctx.root, ctx.identity)
    observed
  end

  defp git(root, args) do
    {output, exit} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert exit == 0, output
    String.trim(output)
  end
end
