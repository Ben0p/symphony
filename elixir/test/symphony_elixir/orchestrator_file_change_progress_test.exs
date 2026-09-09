defmodule SymphonyElixir.OrchestratorFileChangeProgressTest do
  use SymphonyElixir.TestSupport

  test "completed patch progress survives token growth but replay cannot keep a read-only loop alive" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_stall_timeout_ms: 0,
      codex_max_no_progress_tokens: 250_000,
      codex_max_total_tokens: 500_000
    )

    issue = %Issue{
      id: "issue-completed-patch",
      identifier: "MT-PATCH",
      state: "In Progress",
      dispatchable: true
    }

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :PatchOrchestrator))
    worker = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :kill)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    now = DateTime.utc_now()

    entry = %{
      pid: worker,
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      workspace_path: "/workspace/task",
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

    :sys.replace_state(pid, fn state ->
      %{state | running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}
    end)

    send(
      pid,
      {:codex_worker_update, issue.id,
       %{
         event: :session_started,
         timestamp: now,
         session_id: "thread-turn",
         thread_id: "thread",
         turn_id: "turn"
       }}
    )

    send_usage(pid, issue.id, 245_000)

    # This is the actual app-server envelope: the item type is nested under a generic method.
    patch = %{
      event: :notification,
      timestamp: now,
      payload: %{
        "method" => "item/completed",
        "params" => %{
          "threadId" => "thread",
          "turnId" => "turn",
          "item" => %{
            "id" => "exec-patch",
            "type" => "fileChange",
            "status" => "completed",
            "changes" => [
              %{"path" => "/workspace/task/probe.mjs", "kind" => %{"type" => "add"}, "diff" => "+probe"}
            ]
          }
        }
      }
    }

    send(pid, {:codex_worker_update, issue.id, patch})
    state = :sys.get_state(pid)
    assert state.running[issue.id].codex_durable_progress_token_baseline == 245_000
    assert state.running[issue.id].codex_progress_token_baseline == 245_000

    send_usage(pid, issue.id, 293_132)
    send(pid, :run_poll_cycle)
    assert Map.has_key?(:sys.get_state(pid).running, issue.id)
    assert Process.alive?(worker)

    send_usage(pid, issue.id, 499_999)
    send(pid, {:codex_worker_update, issue.id, patch})
    state = :sys.get_state(pid)
    assert state.running[issue.id].codex_durable_progress_token_baseline == 245_000
    assert state.running[issue.id].codex_progress_token_baseline == 245_000
    assert state.running[issue.id].codex_total_tokens == 499_999

    send(pid, :run_poll_cycle)
    state = :sys.get_state(pid)
    refute Map.has_key?(state.running, issue.id)
    refute Process.alive?(worker)
    assert state.retry_attempts[issue.id].stall_diagnostic.durable_token_stall
    assert state.retry_attempts[issue.id].stall_diagnostic.no_durable_progress_tokens == 254_999
  end

  test "stale and unbound managed session starts cannot retarget a current attempt" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :StaleStartOrchestrator))
    issue_id = "issue-restarted-patch"

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    entry = %{
      execution_token: %{issue_id: issue_id, generation: 2},
      execution_session_id: "worker:#{issue_id}:2",
      session_id: "current-thread-current-turn",
      codex_session_identity: %{thread_id: "current-thread", turn_id: "current-turn"},
      codex_total_tokens: 90_000,
      codex_durable_progress_token_baseline: 20_000
    }

    :sys.replace_state(pid, fn state -> %{state | running: %{issue_id => entry}} end)

    start = %{
      event: :session_started,
      timestamp: DateTime.utc_now(),
      session_id: entry.session_id,
      thread_id: "current-thread",
      turn_id: "current-turn"
    }

    for identity <- [
          %{},
          %{execution_token: %{issue_id: issue_id, generation: 1}, execution_session_id: "worker:#{issue_id}:1"}
        ] do
      send(pid, {:codex_worker_update, issue_id, Map.merge(start, identity)})
      assert :sys.get_state(pid).running[issue_id] == entry
    end

    current_start =
      Map.merge(start, %{
        execution_token: entry.execution_token,
        execution_session_id: entry.execution_session_id,
        session_id: "next-thread-next-turn",
        thread_id: "next-thread",
        turn_id: "next-turn"
      })

    send(pid, {:codex_worker_update, issue_id, current_start})
    updated = :sys.get_state(pid).running[issue_id]
    assert updated.codex_session_identity == %{thread_id: "next-thread", turn_id: "next-turn"}
    assert updated.session_id == "next-thread-next-turn"
    assert updated.codex_durable_progress_token_baseline == 90_000
  end

  defp send_usage(pid, issue_id, total) do
    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "thread/tokenUsage/updated",
           "params" => %{
             "tokenUsage" => %{
               "total" => %{
                 "inputTokens" => total - 5_000,
                 "outputTokens" => 5_000,
                 "totalTokens" => total
               }
             }
           }
         }
       }}
    )
  end
end
