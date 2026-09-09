Code.require_file("../support/managed_responsibility_fixture.exs", __DIR__)

defmodule SymphonyElixir.ManagedTokenBudgetRuntimeTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{ManagedResponsibility, ResponsibilityGraph}
  alias SymphonyElixir.ManagedResponsibilityFixture, as: Fixture
  alias SymphonyElixir.ManagedTokenBudget.Runtime

  setup do
    options = [tracker_kind: "memory", max_concurrent_agents: 1, codex_stall_timeout_ms: 0, codex_max_total_tokens: 500_000]
    root = Path.dirname(Workflow.workflow_file_path())
    options = Keyword.put(options, :workspace_root, Path.join(root, "workspaces"))
    write_workflow_file!(Workflow.workflow_file_path(), options)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    now = System.system_time(:millisecond)
    {:ok, manifest} = ManagedResponsibility.decode(Fixture.payload(now), Fixture.context(), now)
    {:ok, graph, _} = ResponsibilityGraph.activate(ResponsibilityGraph.new(), now)
    runtime = %{managed_delegations: manifest}
    state = Fixture.initialize_budget(%Orchestrator.State{responsibility_graph: graph, work_package_runtime: runtime})
    issue = Fixture.issue(1)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    {:ok, state, token, session, _, _} = Orchestrator.admit_execution_for_test(state, issue, nil)
    name = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_options = [name: name, work_package_runtime: state.work_package_runtime]
    child = Supervisor.child_spec({Orchestrator, start_options}, id: name)
    pid = start_supervised!(child)
    assert is_map(Orchestrator.responsibility_snapshot(pid))
    worker = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(worker, :kill) end)
    at = DateTime.utc_now()

    entry = %{
      pid: worker,
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      execution_token: token,
      execution_session_id: session,
      session_id: "thread-turn",
      codex_session_identity: %{thread_id: "thread", turn_id: "turn"},
      workspace_path: nil,
      started_at: at,
      last_codex_timestamp: at,
      last_codex_event: :session_started,
      last_codex_message: nil,
      turn_count: 1,
      codex_total_tokens: 0,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_last_reported_total_tokens: 0
    }

    :sys.replace_state(pid, fn current ->
      %{current | running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), execution_fence: state.execution_fence, responsibility_graph: state.responsibility_graph, tick_token: nil}
    end)

    %{pid: pid, worker: worker, entry: entry, issue: issue, child: child, name: name, state: state}
  end

  test "real OTP usage rejects stale identity, records queued overshoot, and survives restart", c do
    send_usage(c.pid, %{c.entry | execution_session_id: "stale"}, 999_999)
    assert :sys.get_state(c.pid).codex_issue_totals[c.issue.id] == 0
    send_usage(c.pid, c.entry, 400_000)
    assert :sys.get_state(c.pid).codex_issue_totals[c.issue.id] == 400_000
    send_usage(c.pid, c.entry, 500_001)
    send_usage(c.pid, c.entry, 500_050)
    state = :sys.get_state(c.pid)
    assert state.codex_issue_totals[c.issue.id] == 500_050
    refute Map.has_key?(state.running, c.issue.id)
    refute Process.alive?(c.worker)
    assert state.managed_token_budget_error == nil
    assert Runtime.release_totals(state, c.issue.id)[c.issue.id] == 500_050
    assert {:error, _} = Orchestrator.admit_execution_for_test(state, c.issue, nil)
    assert state.execution_fence == c.state.execution_fence
    stop_supervised!(c.name)
    restarted = start_supervised!(c.child)
    restored = :sys.get_state(restarted)
    assert restored.codex_issue_totals[c.issue.id] == 500_050
    assert {:error, _} = Orchestrator.admit_execution_for_test(restored, c.issue, nil)
    assert restored.running == %{}
  end

  test "a changed ledger blocks the running worker and startup even after bytes are restored", c do
    path = c.state.managed_token_budget.path
    before = File.read!(path)
    File.write!(path, before <> "broken\n")
    send_usage(c.pid, c.entry, 10)
    state = :sys.get_state(c.pid)
    assert state.managed_token_budget_error
    assert state.codex_issue_totals[c.issue.id] == 0
    assert state.execution_fence == c.state.execution_fence
    refute Process.alive?(c.worker)
    stop_supervised!(c.name)
    File.write!(path, before)
    assert {:error, _} = start_supervised(c.child)
    assert File.regular?(path <> ".blocked")
  end

  test "unknown issues and generations below the explicit floor cannot admit", c do
    state = :sys.get_state(c.pid)
    unknown = %{c.issue | id: "33333333-3333-4333-8333-333333333333"}
    assert {:error, _} = Orchestrator.admit_execution_for_test(state, unknown, nil)
    assert {:error, _} = Runtime.generation(state, %{issue_id: c.issue.id, generation: 0})
    assert state.execution_fence == c.state.execution_fence
  end

  defp send_usage(pid, entry, total) do
    send(
      pid,
      {:codex_worker_update, entry.issue.id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         execution_token: entry.execution_token,
         execution_session_id: entry.execution_session_id,
         payload: %{"method" => "thread/tokenUsage/updated", "params" => %{"threadId" => "thread", "tokenUsage" => %{"total" => %{"totalTokens" => total}}}}
       }}
    )
  end
end
