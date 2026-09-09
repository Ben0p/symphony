Code.require_file("../support/managed_responsibility_fixture.exs", __DIR__)

defmodule SymphonyElixir.ManagedTokenBudgetStopTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{ExecutionFence, ManagedResponsibility, ManagedTokenBudget, ResponsibilityGraph}
  alias SymphonyElixir.ManagedResponsibilityFixture, as: Fixture
  alias SymphonyElixir.ManagedTokenBudget.{Runtime, Stop}

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    options = [tracker_kind: "memory", codex_max_total_tokens: 500_000, workspace_root: Path.join(root, "workspaces")]
    write_workflow_file!(Workflow.workflow_file_path(), options)
    now = System.system_time(:millisecond)
    {:ok, manifest} = ManagedResponsibility.decode(Fixture.payload(now), Fixture.context(), now)
    {:ok, graph, _} = ResponsibilityGraph.activate(ResponsibilityGraph.new(), now)
    runtime = %{managed_delegations: manifest}
    state = %Orchestrator.State{responsibility_graph: graph, codex_totals: %{}, work_package_runtime: runtime}
    state = Fixture.initialize_budget(state)
    issue = Fixture.issue(1)
    {:ok, state, token, session, _, _} = Orchestrator.admit_execution_for_test(state, issue, nil)
    {pid, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    entry = %{
      pid: pid,
      ref: ref,
      issue: issue,
      identifier: issue.identifier,
      execution_token: token,
      execution_session_id: session,
      session_id: "thread-turn",
      codex_session_identity: %{thread_id: "thread"},
      started_at: DateTime.utc_now()
    }

    %{state: state, entry: entry, issue: issue}
  end

  test "drain persists matching queued usage and leaves unrelated or stale messages", c do
    send(self(), :unrelated)
    stale = update(%{c.entry | execution_session_id: "stale"}, 999)
    send(self(), {:codex_worker_update, c.issue.id, stale})
    send(self(), {:codex_worker_update, c.issue.id, update(c.entry, 100)})
    send(self(), {:codex_worker_update, c.issue.id, update(c.entry, 140)})
    {state, entry} = Stop.drain(c.state, c.issue.id, c.entry, &integrate/3)
    assert entry.codex_last_reported_total_tokens == 140
    assert state.codex_issue_totals[c.issue.id] == 140
    assert_receive :unrelated
    assert_receive {:codex_worker_update, _, ^stale}
    assert {:ok, restored} = Runtime.load(%{state | codex_issue_totals: %{}})
    assert restored.codex_issue_totals[c.issue.id] == 140
  end

  test "a live process cannot be drained as confirmed stopped", c do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    {state, _} = Stop.drain(c.state, c.issue.id, %{c.entry | pid: pid}, &integrate/3)
    assert state.managed_token_budget_error
    assert state.execution_fence == c.state.execution_fence
    assert {:error, _} = Runtime.load(state)
  end

  test "changed accounting during drain retains the fence and a durable restart hold", c do
    File.write!(c.state.managed_token_budget.path, "corrupt\n")
    send(self(), {:codex_worker_update, c.issue.id, update(c.entry, 200)})
    second = update(c.entry, 300)
    send(self(), {:codex_worker_update, c.issue.id, second})
    {state, _} = Stop.drain(c.state, c.issue.id, c.entry, &integrate/3)
    assert state.managed_token_budget_error
    assert state.execution_fence == c.state.execution_fence
    assert Runtime.release_totals(state, c.issue.id) == state.codex_issue_totals
    assert {:error, _} = Runtime.load(state)
    assert_receive {:codex_worker_update, _, ^second}
  end

  test "bounded drain exhaustion is held for reconciliation", c do
    for _ <- 1..10_001 do
      send(self(), {:codex_worker_update, c.issue.id, update(c.entry, 0)})
    end

    {state, _} = Stop.drain(c.state, c.issue.id, c.entry, fn state, entry, _ -> {state, entry} end)
    assert {:managed_usage_drain_limit, :ok} = state.managed_token_budget_error
    assert_receive {:codex_worker_update, _, _}
    assert {:error, _} = Runtime.load(state)
  end

  test "another worker DOWN cannot release ownership while accounting is held", c do
    state = Runtime.latch(c.state, :other_worker_storage_failure)
    state = %{state | running: %{c.issue.id => c.entry}}
    {:noreply, after_down} = Orchestrator.handle_info({:DOWN, c.entry.ref, :process, c.entry.pid, :normal}, state)
    assert after_down.execution_fence == c.state.execution_fence
    assert after_down.responsibility_graph == c.state.responsibility_graph
    assert after_down.blocked[c.issue.id].error == "managed token accounting requires reconciliation"
    assert ExecutionFence.validate(after_down.execution_fence) == :ok
  end

  test "replayed usage with a foreign thread cannot be attributed to the current execution", c do
    entry = Map.put(c.entry, :codex_last_reported_total_tokens, 50)
    state = Runtime.observe(c.state, c.issue.id, entry, %{payload: %{"params" => %{"threadId" => "foreign"}}})
    assert {:managed_usage_thread_mismatch, :ok} = state.managed_token_budget_error
    assert state.codex_issue_totals[c.issue.id] == 0
    assert {:error, _} = ManagedTokenBudget.load(state.managed_token_budget.path, state.managed_token_budget.identity)
  end

  test "non-map startup payloads retain normal zero-usage handling", c do
    state = Runtime.observe(c.state, c.issue.id, c.entry, %{payload: "startup diagnostic"})
    assert state.managed_token_budget_error == nil
    assert state.codex_issue_totals[c.issue.id] == 0
  end

  defp integrate(state, entry, update) do
    entry = Map.put(entry, :codex_last_reported_total_tokens, update.total)
    {Runtime.observe(state, entry.issue.id, entry, update), entry}
  end

  defp update(entry, total) do
    entry
    |> Map.take([:execution_token, :execution_session_id])
    |> Map.merge(%{event: :notification, timestamp: DateTime.utc_now(), total: total})
  end
end
