defmodule SymphonyElixir.OrchestratorCheckoutProgressTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ExecutionFence, ResponsibilityGraph}

  setup do
    limits = [codex_max_no_progress_tokens: 250_000, codex_max_total_tokens: 1_000_000]
    options = [tracker_kind: "memory", codex_stall_timeout_ms: 0] ++ limits
    write_workflow_file!(Workflow.workflow_file_path(), options)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    server = start_supervised!({Orchestrator, name: Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")})
    worker = spawn(fn -> worker_loop() end)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    issue = %Issue{id: "checkout-progress", identifier: "CP-1", title: "Useful progress", state: "In Progress", dispatchable: true}
    identity = %{issue_id: issue.id, repository: "example/repository", worktree: "/workspace/CP-1", branch: "codex/CP-1"}
    now_ms = System.system_time(:millisecond)
    {:ok, fence, token} = ExecutionFence.admit(ExecutionFence.new(), identity, now_ms)
    identity = Map.merge(identity, %{generation: token.generation, session_id: "worker:CP-1:1"})
    session = Map.merge(identity, %{role: :worker, process_id: "process-CP-1", linear_state: "In Progress", pr_state: "OPEN", head: head("a"), last_heartbeat_at: now_ms})
    {:ok, fence, :registered} = ExecutionFence.register(fence, token, :worker, session, now_ms)
    now = DateTime.utc_now()

    entry = %{
      pid: worker,
      ref: Process.monitor(worker),
      identifier: issue.identifier,
      issue: issue,
      workspace_path: identity.worktree,
      execution_token: token,
      execution_session_id: identity.session_id,
      responsibility_delegation_id: nil,
      session_id: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      codex_progress_token_baseline: 0,
      codex_durable_progress_token_baseline: 0,
      last_codex_message: nil,
      last_codex_timestamp: now,
      last_codex_event: :notification,
      started_at: now,
      turn_count: 1
    }

    :sys.replace_state(server, &%{&1 | running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), execution_fence: fence})
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    %{server: server, worker: worker, issue: issue, identity: identity, token: token, fence: fence}
  end

  test "actual caller receives current-known durable credit while delayed usage and replay remain charged", ctx do
    usage(ctx, 245_000)
    baseline = checkpoint(ctx, :baseline, 0, nil, head("a"))
    assert :ok = call(ctx, baseline)
    assert entry(ctx).codex_durable_progress_token_baseline == 0
    durable = checkpoint(ctx, :durable, 1, head("a"), head("b"))
    assert :ok = call(ctx, durable)
    assert entry(ctx).codex_durable_progress_token_baseline == 245_000
    assert entry(ctx).codex_progress_token_baseline == 0
    assert entry(ctx).codex_last_durable_progress_method == "managed_checkout_commit"
    assert %DateTime{} = entry(ctx).codex_last_durable_progress_timestamp
    assert :sys.get_state(ctx.server).execution_fence == ctx.fence
    usage(ctx, 293_132)
    assert entry(ctx).codex_durable_progress_token_baseline == 245_000
    assert entry(ctx).codex_total_tokens == 293_132
    assert {:error, _} = call(ctx, durable)
    assert :ok = call(ctx, checkpoint(ctx, :observed, 2, head("b"), head("c")))
    assert entry(ctx).codex_durable_progress_token_baseline == 245_000
    usage(ctx, 499_999)
    assert {:error, _} = call(ctx, durable)
    assert entry(ctx).codex_durable_progress_token_baseline == 245_000
    send(ctx.server, :run_poll_cycle)
    state = :sys.get_state(ctx.server)
    refute Map.has_key?(state.running, ctx.issue.id)
    assert state.retry_attempts[ctx.issue.id].stall_diagnostic.durable_token_stall
    assert state.retry_attempts[ctx.issue.id].stall_diagnostic.no_durable_progress_tokens == 254_999
    assert {:error, _} = GenServer.call(ctx.server, {:execution_checkout_progress, ctx.issue.id, durable})
  end

  test "wrong sender, identity, ordering and malformed messages cannot mutate running state", ctx do
    baseline = checkpoint(ctx, :baseline, 0, nil, head("a"))
    assert {:error, _} = GenServer.call(ctx.server, {:execution_checkout_progress, ctx.issue.id, baseline})
    assert :ok = call(ctx, baseline)
    durable = checkpoint(ctx, :durable, 1, head("a"), head("b"))
    unchanged = entry(ctx)
    invalid = [nil, %{}, baseline, %{durable | sequence: 3}, %{durable | previous_head: head("d")}, %{durable | head: head("a")}, %{durable | tree_changed: false}, Map.put(durable, :extra, true)]

    identities =
      for {key, value} <- [issue_id: "other", generation: 2, session_id: "stale", repository: "other/repo", branch: "main", worktree: "/other"],
          do: %{durable | identity: Map.put(ctx.identity, key, value)}

    for rejected <- invalid ++ identities do
      assert {:error, _} = call(ctx, rejected)
      assert entry(ctx) == unchanged
    end
  end

  test "fenced or unreconciled authority cannot accept a later checkpoint", ctx do
    assert :ok = call(ctx, checkpoint(ctx, :baseline, 0, nil, head("a")))
    durable = checkpoint(ctx, :durable, 1, head("a"), head("b"))

    for execution_change <- [%{status: :terminal}, %{ownership: :unreconciled}] do
      :sys.replace_state(ctx.server, fn state ->
        fence = put_in(ctx.fence.executions[ctx.issue.id], Map.merge(ctx.fence.executions[ctx.issue.id], execution_change))
        %{state | execution_fence: fence}
      end)

      assert {:error, _} = call(ctx, durable)
      assert entry(ctx).codex_durable_progress_token_baseline == 0
    end
  end

  test "enforced responsibility requires a current delegation", ctx do
    assert :ok = call(ctx, checkpoint(ctx, :baseline, 0, nil, head("a")))
    {:ok, graph, :activated} = ResponsibilityGraph.activate(ResponsibilityGraph.new(), System.system_time(:millisecond))

    :sys.replace_state(ctx.server, fn state ->
      running = Map.update!(state.running, ctx.issue.id, &Map.put(&1, :responsibility_delegation_id, "missing-delegation"))
      %{state | responsibility_graph: graph, running: running}
    end)

    assert {:error, _} = call(ctx, checkpoint(ctx, :durable, 1, head("a"), head("b")))
    assert entry(ctx).codex_durable_progress_token_baseline == 0
  end

  defp head(character), do: String.duplicate(character, 40)
  defp entry(ctx), do: :sys.get_state(ctx.server).running[ctx.issue.id]

  defp checkpoint(ctx, kind, sequence, previous, current) do
    changed = kind == :durable
    fields = %{kind: kind, sequence: sequence, previous_head: previous, head: current, tree_changed: changed}
    Map.put(fields, :identity, ctx.identity)
  end

  defp call(ctx, checkpoint) do
    ref = make_ref()
    send(ctx.worker, {self(), ref, ctx.server, ctx.issue.id, checkpoint})
    assert_receive {^ref, reply}, 1_000
    reply
  end

  defp worker_loop do
    receive do
      {caller, ref, server, issue_id, checkpoint} ->
        send(caller, {ref, GenServer.call(server, {:execution_checkout_progress, issue_id, checkpoint})})
        worker_loop()
    end
  end

  defp usage(ctx, total) do
    send(
      ctx.server,
      {:codex_worker_update, ctx.issue.id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         execution_token: ctx.token,
         execution_session_id: ctx.identity.session_id,
         payload: %{"method" => "thread/tokenUsage/updated", "params" => %{"tokenUsage" => %{"total" => %{"inputTokens" => total - 5_000, "outputTokens" => 5_000, "totalTokens" => total}}}}
       }}
    )

    :sys.get_state(ctx.server)
  end
end
