defmodule SymphonyElixir.AgentRunnerManagedCheckoutTest do
  use SymphonyElixir.TestSupport

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    source = Path.join(root, "origin")
    pool = Path.join(root, "pool")
    File.mkdir!(source)
    File.mkdir!(pool)
    git(source, ["init", "-b", "main"])
    git(source, ["config", "user.name", "Checkout test"])
    git(source, ["config", "user.email", "checkout@example.invalid"])
    File.write!(Path.join(source, "README.md"), "fixture\n")
    git(source, ["add", "README.md"])
    git(source, ["commit", "-m", "initial"])
    issue = %Issue{id: "checkout-launch", identifier: "MC-1", title: "managed checkout", state: "In Progress"}

    identity = %{
      issue_id: issue.id,
      generation: 1,
      session_id: "worker:checkout-launch:1",
      repository: "example/repository",
      worktree: Path.join(pool, issue.identifier),
      branch: "codex/MC-1"
    }

    trace = Path.join(root, "codex.jsonl")
    started = Path.join(root, "codex-started")
    executable = Path.join(root, "fake-codex")

    File.write!(executable, """
    #!/bin/bash
    printf started > #{quote_path(started)}
    n=0
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> #{quote_path(trace)}
      n=$((n+1))
      case "$n" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"checkout-thread"}}}' ;;
        4) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"checkout-turn"}}}'
           printf '%s\\n' '{"method":"turn/completed"}' ;;
      esac
    done
    """)

    File.chmod!(executable, 0o755)

    workflow = [
      workspace_root: pool,
      codex_command: quote_path(executable),
      hook_after_create:
        "git clone --no-local #{quote_path(source)} . && " <>
          "git remote set-url origin https://github.com/example/repository.git"
    ]

    write_workflow_file!(Workflow.workflow_file_path(), workflow)
    %{issue: issue, identity: identity, workflow: workflow, trace: trace, started: started}
  end

  test "real clone reaches app-server on its prepared branch and reports observed identity", ctx do
    assert :ok =
             AgentRunner.run(ctx.issue, self(),
               execution_checkout: ctx.identity,
               execution_fence_guard: fn -> :ok end,
               execution_session_id: ctx.identity.session_id,
               issue_state_fetcher: fn [_id] -> {:ok, [%{ctx.issue | state: "Done"}]} end
             )

    assert File.read!(ctx.started) == "started"
    assert git(ctx.identity.worktree, ["branch", "--show-current"]) == ctx.identity.branch
    assert_receive {:worker_runtime_info, "checkout-launch", %{branch: "codex/MC-1", head: head}}
    assert head == git(ctx.identity.worktree, ["rev-parse", "HEAD"])

    request =
      ctx.trace
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["method"] == "turn/start"))

    prompt = request["params"]["input"] |> Enum.map_join("\n", & &1["text"])
    assert prompt =~ "Managed checkout authority for this execution:"
    assert prompt =~ "branch codex/MC-1"
    assert prompt =~ "generic workflow instructions to create or change a branch do not apply"
  end

  test "silent turn stays alive until observed durable checkout progress", ctx do
    root = Path.dirname(ctx.trace)
    ack = Path.join(root, "silent-turn-ack")
    executable = Path.join(root, "silent-turn-codex")

    File.write!(executable, """
    #!/bin/sh
    count=0
    while IFS= read -r _line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"silent-thread"}}}' ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"silent-turn"}}}'
          git config user.name "Silent turn fixture"
          git config user.email silent@example.invalid
          printf native > native.txt
          git add native.txt && git commit -m observed >/dev/null 2>&1
          waited=0
          while [ ! -f #{quote_path(ack)} ] && [ "$waited" -lt 100 ]; do
            sleep 0.05
            waited=$((waited + 1))
          done
          [ -f #{quote_path(ack)} ] || exit 41
          printf '%s\\n' '{"method":"turn/completed"}'
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(executable, 0o755)

    workflow =
      Keyword.merge(ctx.workflow,
        codex_command: "#{quote_path(executable)} app-server",
        codex_turn_timeout_ms: 5_000
      )

    write_workflow_file!(Workflow.workflow_file_path(), workflow)
    identity = ctx.identity
    expected_branch = identity.branch

    assert :ok =
             AgentRunner.run(ctx.issue, self(),
               execution_checkout: identity,
               execution_fence_guard: fn -> :ok end,
               execution_session_id: identity.session_id,
               execution_checkout_checkpoint: fn checkpoint ->
                 send(self(), {:silent_checkpoint, checkpoint})
                 if checkpoint.kind == :durable, do: File.write!(ack, "durable")
                 :ok
               end,
               issue_state_fetcher: fn [_id] -> {:ok, [%{ctx.issue | state: "Done"}]} end
             )

    assert_receive {:silent_checkpoint, baseline}
    assert baseline.kind == :baseline
    assert baseline.sequence == 0
    assert baseline.identity == identity
    assert_receive {:silent_checkpoint, durable}
    assert durable.kind == :durable
    assert durable.sequence == 1
    assert durable.previous_head == baseline.head
    assert durable.identity == identity
    assert durable.tree_changed
    final_head = git(identity.worktree, ["rev-parse", "HEAD"])
    assert durable.head == final_head
    assert final_head != baseline.head
    assert File.read!(Path.join(identity.worktree, "native.txt")) == "native"
    assert File.read!(ack) == "durable"
    assert_receive {:worker_runtime_info, "checkout-launch", %{branch: ^expected_branch, head: _}}
    assert_receive {:worker_runtime_info, "checkout-launch", %{branch: ^expected_branch, head: ^final_head}}
    refute_receive {:silent_checkpoint, _}, 1_200
    refute_received {:symphony_managed_checkout_tick, _}
  end

  test "a before-run hook changing the branch never launches Codex or runs the after hook", ctx do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(ctx.workflow,
        hook_before_run: "git switch main",
        hook_after_run: "printf unexpected > after-hook.txt"
      )
    )

    assert_raise RuntimeError, ~r/managed_checkout_git_identity_mismatch/, fn ->
      AgentRunner.run(ctx.issue, self(),
        execution_checkout: ctx.identity,
        execution_fence_guard: fn -> :ok end,
        execution_checkout_checkpoint: fn checkpoint ->
          send(self(), {:preflight_checkpoint, checkpoint.kind})
          :ok
        end
      )
    end

    assert_receive {:preflight_checkpoint, :baseline}
    refute_received {:preflight_checkpoint, _}
    refute Enum.any?(Process.get_keys(), &match?({SymphonyElixir.ManagedCheckout.Progress, _}, &1))
    refute File.exists?(ctx.started)
    refute File.exists?(Path.join(ctx.identity.worktree, "after-hook.txt"))
    assert git(ctx.identity.worktree, ["branch", "--show-current"]) == "main"
    assert File.exists?(Path.join(ctx.identity.worktree, ".git/symphony-execution.json"))
    refute_received {:codex_worker_update, _, _}
  end

  test "a different generation preserves dirty work and stops before hooks or Codex", ctx do
    assert {:ok, _} = Workspace.create_for_execution(ctx.issue, ctx.identity, nil, fn -> :ok end)
    unique = Path.join(ctx.identity.worktree, "unique.txt")
    File.write!(unique, "retain my work")
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(ctx.workflow, :hook_before_run, "printf unexpected > before-hook.txt"))

    assert_raise RuntimeError, ~r/managed_checkout_marker_identity_mismatch/, fn ->
      AgentRunner.run(ctx.issue, self(),
        execution_checkout: %{ctx.identity | generation: 2},
        execution_fence_guard: fn -> :ok end
      )
    end

    refute File.exists?(ctx.started)
    refute File.exists?(Path.join(ctx.identity.worktree, "before-hook.txt"))
    assert File.read!(unique) == "retain my work"
    refute_received {:worker_runtime_info, _, _}
  end

  test "a hook revoking execution authority prevents startup and the after hook", ctx do
    revoked = Path.join(ctx.identity.worktree, "revoked.txt")

    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(ctx.workflow,
        hook_before_run: "printf revoked > revoked.txt",
        hook_after_run: "printf unexpected > after-hook.txt"
      )
    )

    guard = fn -> if File.exists?(revoked), do: {:error, :terminal_fenced}, else: :ok end

    assert_raise RuntimeError, ~r/terminal_fenced/, fn ->
      AgentRunner.run(ctx.issue, self(), execution_checkout: ctx.identity, execution_fence_guard: guard)
    end

    assert File.read!(revoked) == "revoked"
    refute File.exists?(ctx.started)
    refute File.exists?(Path.join(ctx.identity.worktree, "after-hook.txt"))
  end

  test "marker collision preserves preparation evidence without Codex or after hook", ctx do
    hook = Keyword.fetch!(ctx.workflow, :hook_after_create) <> " && mkdir .git/symphony-execution.json"

    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(ctx.workflow,
        hook_after_create: hook,
        hook_after_run: "printf unexpected > after-hook.txt"
      )
    )

    assert_raise RuntimeError, ~r/managed_checkout_path_exists_or_unreadable/, fn ->
      AgentRunner.run(ctx.issue, self(), execution_checkout: ctx.identity, execution_fence_guard: fn -> :ok end)
    end

    assert File.dir?(Path.join(ctx.identity.worktree, ".git/symphony-execution.json"))
    refute File.exists?(ctx.started)
    refute File.exists?(Path.join(ctx.identity.worktree, "after-hook.txt"))
  end

  test "authorized session startup failure retains the existing best-effort after hook", ctx do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(ctx.workflow,
        codex_command: "exit 23",
        hook_after_run: "printf authorized > after-hook.txt"
      )
    )

    assert_raise RuntimeError, fn ->
      AgentRunner.run(ctx.issue, self(), execution_checkout: ctx.identity, execution_fence_guard: fn -> :ok end)
    end

    assert File.read!(Path.join(ctx.identity.worktree, "after-hook.txt")) == "authorized"
    assert git(ctx.identity.worktree, ["branch", "--show-current"]) == ctx.identity.branch
  end

  test "commit checkpoints keep one cursor through initial reporting and final hooks", ctx do
    before_hook =
      "git config user.name 'Progress fixture' && git config user.email progress@example.invalid && " <>
        "printf before > README.md && git add README.md && git commit -m before"

    after_hook = "printf after > README.md && git add README.md && git commit -m after"
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.merge(ctx.workflow, hook_before_run: before_hook, hook_after_run: after_hook))

    assert :ok =
             AgentRunner.run(ctx.issue, self(),
               execution_checkout: ctx.identity,
               execution_fence_guard: fn -> {:ok, %{authorized: true}} end,
               execution_session_id: ctx.identity.session_id,
               execution_checkout_checkpoint: fn checkpoint ->
                 send(self(), {:progress_checkpoint, checkpoint})
                 :ok
               end,
               issue_state_fetcher: fn [_id] -> {:ok, [%{ctx.issue | state: "Done"}]} end
             )

    assert_receive {:progress_checkpoint, %{kind: :baseline, sequence: 0}}
    assert_receive {:progress_checkpoint, %{kind: :durable, sequence: 1}}
    assert_receive {:progress_checkpoint, %{kind: :durable, sequence: 2}}
    refute_received {:progress_checkpoint, _}
    refute Enum.any?(Process.get_keys(), &match?({SymphonyElixir.ManagedCheckout.Progress, _}, &1))
  end

  test "a final checkpoint rejection exits as failure while preserving the changed checkout", ctx do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(ctx.workflow,
        hook_before_run: "git config user.name 'Progress fixture' && git config user.email progress@example.invalid",
        hook_after_run: "printf after > README.md && git add README.md && git commit -m after"
      )
    )

    callback = fn checkpoint ->
      send(self(), {:final_checkpoint, checkpoint.kind})
      if checkpoint.kind == :baseline, do: :ok, else: {:error, :final_checkpoint_rejected}
    end

    assert_raise RuntimeError, ~r/final_checkpoint_rejected/, fn ->
      AgentRunner.run(ctx.issue, self(),
        execution_checkout: ctx.identity,
        execution_fence_guard: fn -> :ok end,
        execution_checkout_checkpoint: callback,
        issue_state_fetcher: fn [_id] -> {:ok, [%{ctx.issue | state: "Done"}]} end
      )
    end

    assert_receive {:final_checkpoint, :baseline}
    assert_receive {:final_checkpoint, :durable}
    refute_received {:final_checkpoint, _}
    assert File.read!(Path.join(ctx.identity.worktree, "README.md")) == "after"
    refute Enum.any?(Process.get_keys(), &match?({SymphonyElixir.ManagedCheckout.Progress, _}, &1))
  end

  defp git(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(output)
  end

  defp quote_path(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"
end
