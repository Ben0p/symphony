Code.require_file("../support/managed_responsibility_fixture.exs", __DIR__)

defmodule SymphonyElixir.WorkPackageClaimRecoveryTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{ExecutionFence, ManagedResponsibility, ResponsibilityGraph, WorkPackageClaim}
  alias SymphonyElixir.ManagedResponsibilityFixture, as: Fixture
  alias SymphonyElixir.WorkPackageClaim.{Dispatch, Journal, Recovery}

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: Path.join(root, "workspaces"), codex_max_total_tokens: 500_000)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    now = System.system_time(:millisecond)
    {:ok, graph, _} = ResponsibilityGraph.activate(ResponsibilityGraph.new(), now)
    {:ok, manifest} = ManagedResponsibility.decode(Fixture.payload(now), Fixture.context(), now)

    runtime = %{
      managed_delegations: manifest,
      base_url: "http://127.0.0.1:1",
      runner_token: "test-token",
      attestation_key: "test-key",
      runner_id: "runner-test",
      managed_project_profile_id: "profile-test",
      journal_path: Path.join(root, "claims.json")
    }

    state = %Orchestrator.State{
      execution_fence: ExecutionFence.new(),
      responsibility_graph: graph,
      execution_fence_path: Config.execution_fence_state_path(),
      responsibility_graph_path: Config.responsibility_graph_state_path(),
      work_package_runtime: runtime,
      max_concurrent_agents: 1
    }

    issue = Fixture.issue(1)
    {:ok, state, token, session, delegation, lease} = Orchestrator.admit_execution_for_test(state, issue, nil)
    input = claim_input(state, issue)

    request = fn url, _options ->
      if String.ends_with?(url, "/reservations/by-issue"),
        do: {:ok, %Req.Response{status: 200, body: reservation(issue.id)}},
        else: {:error, :response_lost_after_commit}
    end

    assert {:error, {:claim_indeterminate, _}} =
             WorkPackageClaim.claim(input,
               request_fun: request,
               now_fun: fn -> DateTime.from_unix!(now - 6_000, :millisecond) end
             )

    %{
      state: state,
      issue: issue,
      input: input,
      token: token,
      session: session,
      delegation: delegation,
      lease: lease,
      runtime: runtime
    }
  end

  test "real orchestrator restart recovers the same pre-spawn authority", context do
    name = Module.concat(__MODULE__, "Restart#{System.unique_integer([:positive])}")
    pid = start_supervised!({Orchestrator, name: name, work_package_runtime: context.runtime})
    assert is_map(Orchestrator.responsibility_snapshot(pid))
    state = :sys.get_state(pid)
    assert state.running == %{}
    assert {:ok, recovered, token, session, delegation, lease} = Orchestrator.admit_execution_for_test(state, context.issue, nil)
    assert {token, session, delegation, lease} == {context.token, context.session, context.delegation, context.lease}
    assert recovered.execution_fence.history == context.state.execution_fence.history
    assert recovered.execution_fence.executions[context.issue.id].generation == 1
    assert recovered.responsibility_graph.delegations[delegation].runtime_lease == lease
  end

  test "pending authority uses its own slot and excludes fresh admission", context do
    assert Orchestrator.should_dispatch_issue_for_test(context.issue, context.state)
    refute Orchestrator.should_dispatch_issue_for_test(Fixture.issue(2), context.state)
    assert {:ok, _state, token, _, _, _} = Orchestrator.admit_execution_for_test(context.state, context.issue, nil)
    assert token == context.token
  end

  test "HTTP commit followed by a closed response is replayed after OTP restart", context do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, reserve_socket} = :gen_tcp.accept(listener, 5_000)
        read_request(reserve_socket)
        reply(reserve_socket, reservation(context.issue.id))
        {:ok, claim_socket} = :gen_tcp.accept(listener, 5_000)
        first = read_request(claim_socket)["attestation"]
        send(parent, {:provider_committed, first})
        :gen_tcp.close(claim_socket)
        {:ok, replay_socket} = :gen_tcp.accept(listener, 5_000)
        replay = read_request(replay_socket)["attestation"]
        assert Map.drop(replay, ["attestedAt", "signature"]) == Map.drop(first, ["attestedAt", "signature"])

        reply(replay_socket, %{
          "projectionId" => "package-1",
          "projectionState" => "active",
          "mutationState" => "applied",
          "claimEvidence" => Map.take(replay, ["responsibleDelegationId", "executionFenceToken", "runtimeLeaseId"])
        })
      end)

    runtime = %{context.runtime | base_url: "http://127.0.0.1:#{port}", journal_path: context.runtime.journal_path <> ".http"}
    state = %{context.state | work_package_runtime: runtime}
    input = claim_input(state, context.issue)

    assert {:error, {:claim_indeterminate, {:provider_request, _}}} =
             WorkPackageClaim.claim(input,
               now_fun: fn -> DateTime.add(DateTime.utc_now(), -6, :second) end
             )

    assert_receive {:provider_committed, committed}
    assert committed["generation"] == 1
    name = Module.concat(__MODULE__, "HttpRestart#{System.unique_integer([:positive])}")
    pid = start_supervised!({Orchestrator, name: name, work_package_runtime: runtime})
    assert is_map(Orchestrator.responsibility_snapshot(pid))
    assert {:ok, recovered, token, _, _, _} = Orchestrator.admit_execution_for_test(:sys.get_state(pid), context.issue, nil)
    assert token == context.token
    assert {:ok, _} = WorkPackageClaim.claim(claim_input(recovered, context.issue))
    assert recovered.running == %{}
    assert :ok = Task.await(server, 5_000)
  end

  test "lost acknowledgement followed by replay requires one durable spawn boundary", context do
    response = fn _url, options ->
      payload = Keyword.fetch!(options, :json).attestation
      assert payload["generation"] == context.token.generation
      assert payload["sessionId"] == context.session

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "projectionId" => "package-1",
           "projectionState" => "active",
           "mutationState" => "applied",
           "claimEvidence" => %{"responsibleDelegationId" => context.delegation, "executionFenceToken" => "#{context.issue.id}:1", "runtimeLeaseId" => context.session}
         }
       }}
    end

    assert {:ok, _} = WorkPackageClaim.claim(context.input, request_fun: response)
    assert :ok = WorkPackageClaim.begin_spawn(context.input)
    assert {:error, _} = WorkPackageClaim.begin_spawn(context.input)
    assert {:error, :claim_spawn_already_attempted} = Orchestrator.admit_execution_for_test(context.state, context.issue, nil)
    assert context.state.running == %{}
  end

  test "missing and corrupt journals retain the fence instead of admitting another generation", context do
    File.rename!(context.runtime.journal_path, context.runtime.journal_path <> ".retained")
    assert {:error, :claim_recovery_journal_missing} = Orchestrator.admit_execution_for_test(context.state, context.issue, nil)
    File.write!(context.runtime.journal_path, "{broken")
    assert {:error, _} = Orchestrator.admit_execution_for_test(context.state, context.issue, nil)
    assert context.state.execution_fence.executions[context.issue.id].generation == 1
  end

  test "a surviving journal prevents fresh admission after loss of the fence", context do
    state = %{context.state | execution_fence: ExecutionFence.new()}
    assert {:error, :claim_exists_without_matching_fence} = Orchestrator.admit_execution_for_test(state, context.issue, nil)
  end

  test "journal read failures leave the real orchestrator fence unchanged during reconciliation", context do
    name = Module.concat(__MODULE__, "MissingJournal#{System.unique_integer([:positive])}")
    pid = start_supervised!({Orchestrator, name: name, work_package_runtime: context.runtime})
    before = :sys.get_state(pid).execution_fence
    File.rename!(context.runtime.journal_path, context.runtime.journal_path <> ".retained")

    assert {:error, :claim_recovery_journal_missing} =
             Orchestrator.reconcile_execution_fence(pid, [], System.system_time(:millisecond), 300_000)

    assert :sys.get_state(pid).execution_fence == before
    File.write!(context.runtime.journal_path, "{broken")
    assert {:error, _} = Orchestrator.reconcile_execution_fence(pid, [], System.system_time(:millisecond), 300_000)
    assert :sys.get_state(pid).execution_fence == before
    assert Recovery.held?(before, context.issue.id)
  end

  test "the adapter cannot bless an unmarked legacy reservation with a new spawn marker", context do
    {:ok, journal} = Journal.load(context.runtime.journal_path)
    [key] = Map.keys(journal.reservations)
    {:ok, legacy} = Journal.put(journal, key, Map.delete(journal.reservations[key], :dispatch))
    assert :ok = Journal.save(context.runtime.journal_path, legacy)

    assert {:error, :legacy_claim_requires_reconciliation} =
             WorkPackageClaim.claim(context.input,
               request_fun: fn _url, _opts -> flunk("legacy authority must not cause an HTTP request") end
             )
  end

  test "generic missing-observation reconciliation preserves proven pre-spawn leases", context do
    now = System.system_time(:millisecond)
    {:ok, claims} = Recovery.unstarted_claims(context.runtime, context.state.execution_fence)
    before = context.state.execution_fence
    assert {:ok, fence, _summary} = ExecutionFence.reconcile_claim_sessions(before, [], claims, now, 300_000)
    assert fence.executions[context.issue.id].leases[context.session].status == :active
    assert {:ok, _, token, _, _, _} = Orchestrator.admit_execution_for_test(%{context.state | execution_fence: fence}, context.issue, nil)
    assert token == context.token

    observation =
      context.state.execution_fence.sessions[context.session]
      |> Map.put(:last_heartbeat_at, now)
      |> Map.put(:head, "actually-observed")

    assert {:ok, observed, _} = ExecutionFence.reconcile_claim_sessions(fence, [observation], claims, now, 300_000)
    assert {:error, _} = Orchestrator.admit_execution_for_test(%{context.state | execution_fence: observed}, context.issue, nil)

    stale = %{observation | generation: observation.generation + 1}
    assert {:ok, contradictory, _} = ExecutionFence.reconcile_claim_sessions(fence, [stale], claims, now, 300_000)
    assert contradictory.executions[context.issue.id].ownership == :contradictory
    assert {:error, _} = Orchestrator.admit_execution_for_test(%{context.state | execution_fence: contradictory}, context.issue, nil)
  end

  test "sixth confirmed attempt remains explicitly blocked across restart without resetting budget", context do
    {:ok, journal} = Journal.load(context.runtime.journal_path)
    [key] = Map.keys(journal.reservations)

    journal =
      Enum.reduce(2..6, journal, fn _attempt, previous ->
        due = DateTime.from_unix!(previous.reservations[key].dispatch.retry_at_ms, :millisecond)
        {:ok, next} = Dispatch.submit(previous, key, context.input, due)
        next
      end)

    {:ok, journal} = Dispatch.confirm(journal, key)
    assert :ok = Journal.save(context.runtime.journal_path, journal)
    name = Module.concat(__MODULE__, "Exhausted#{System.unique_integer([:positive])}")
    pid = start_supervised!({Orchestrator, name: name, work_package_runtime: context.runtime})
    assert {:error, :claim_confirmed_revalidation_required} = Orchestrator.admit_execution_for_test(:sys.get_state(pid), context.issue, nil)
    assert {:ok, restored} = Journal.load(context.runtime.journal_path)
    assert restored.reservations[key].dispatch.attempts == 6
  end

  test "changed owner or expired authorization cannot recover a claim", context do
    assert {:error, _} = Orchestrator.admit_execution_for_test(context.state, %{context.issue | assignee_id: "different-owner"}, nil)
    manifest = context.runtime.managed_delegations
    changed = %{manifest | authority_ref: "different-authority"}
    state = %{context.state | work_package_runtime: %{context.runtime | managed_delegations: changed}}
    assert {:error, _} = Orchestrator.admit_execution_for_test(state, context.issue, nil)
    expired = put_in(context.state.responsibility_graph, [:delegations, context.delegation, :expires_at_ms], 1)
    assert {:error, _} = Orchestrator.admit_execution_for_test(%{context.state | responsibility_graph: expired}, context.issue, nil)
  end

  test "advanced generations and observed worker activity are never rolled back", context do
    {:ok, journal} = Journal.load(context.runtime.journal_path)
    [reservation] = Map.values(journal.reservations)
    assert {:error, _} = ExecutionFence.reconcile_unstarted_claim(context.state.execution_fence, %{reservation | generation: 2})
    fence = put_in(context.state.execution_fence, [:executions, context.issue.id, :leases, context.session, :head], "observed-head")
    assert {:error, _} = ExecutionFence.reconcile_unstarted_claim(fence, reservation)
    {:ok, journal} = Dispatch.begin_spawn(put_in(journal, [:reservations, hd(Map.keys(journal.reservations)), :dispatch, :phase], "confirmed"), hd(Map.keys(journal.reservations)), context.input)
    assert :ok = Journal.save(context.runtime.journal_path, journal)
    assert {:error, :claim_spawn_already_attempted} = Orchestrator.admit_execution_for_test(context.state, context.issue, nil)
  end

  test "cleaned failed attempt admits fresh authority after actual orchestrator restart", context do
    cleaned = cleaned_failed_attempt(context)
    assert :ok = ExecutionFence.Persistence.save(cleaned.execution_fence_path, cleaned.execution_fence)
    assert :ok = ResponsibilityGraph.Persistence.save(cleaned.responsibility_graph_path, cleaned.responsibility_graph)
    journal_before = File.read!(context.runtime.journal_path)
    name = Module.concat(__MODULE__, "FailedRestart#{System.unique_integer([:positive])}")
    pid = start_supervised!({Orchestrator, name: name, work_package_runtime: context.runtime})
    restarted = :sys.get_state(pid)
    parent = restarted.responsibility_graph.delegations[context.delegation].parent_delegation_id
    assert restarted.responsibility_graph.delegations[parent].blocked_on == :restart_reconciliation

    assert {:ok, recovered, token, session, delegation, lease} =
             Orchestrator.admit_execution_for_test(restarted, context.issue, nil)

    assert token.generation == context.token.generation + 1
    refute session == context.session
    assert delegation == context.delegation
    assert lease.generation == token.generation
    assert recovered.responsibility_graph.delegations[parent].status == :active
    assert File.read!(context.runtime.journal_path) == journal_before
    assert Enum.any?(recovered.execution_fence.history, &(&1.generation == context.token.generation and &1.terminal.state == "Failed attempt"))
  end

  test "failed retry refuses changed responsibility and missing cleanup acknowledgement", context do
    cleaned = cleaned_failed_attempt(context)
    {:ok, graph} = ResponsibilityGraph.mark_unreconciled_after_restart(cleaned.responsibility_graph)
    state = %{cleaned | responsibility_graph: graph}
    parent = graph.delegations[context.delegation].parent_delegation_id

    for changed <- [
          put_in(graph, [:delegations, context.delegation, :runtime_lease], context.lease),
          put_in(graph, [:delegations, parent, :blocked_on], :external_decision),
          put_in(graph, [:delegations, parent, :runtime_lease], context.lease),
          put_in(graph, [:delegations, context.delegation, :expires_at_ms], 1)
        ] do
      assert {:error, _} = Orchestrator.admit_execution_for_test(%{state | responsibility_graph: changed}, context.issue, nil)
    end

    assert {:error, _} = Orchestrator.admit_execution_for_test(state, %{context.issue | assignee_id: "different-owner"}, nil)
    {:ok, journal} = Journal.load(context.runtime.journal_path)
    [key] = Map.keys(journal.reservations)
    {:ok, missing} = Journal.put(journal, key, Map.delete(journal.reservations[key], :cleanup_receipts))
    assert :ok = Journal.save(context.runtime.journal_path, missing)
    assert {:error, :claim_terminal_acknowledgement_required} = Orchestrator.admit_execution_for_test(state, context.issue, nil)
    assert graph.delegations[parent].blocked_on == :restart_reconciliation
  end

  defp cleaned_failed_attempt(context) do
    now = System.system_time(:millisecond)
    head = String.duplicate("a", 40)
    evidence_ref = "sha256:" <> String.duplicate("b", 64)
    token = context.token
    {:ok, fence, :released} = ExecutionFence.release(context.state.execution_fence, token, context.session, :orchestrator_stop)
    evidence = %{session_id: context.session, process_id: context.lease.process_id, process_tree: :terminated, evidence_ref: evidence_ref, observed_at_ms: now}
    {:ok, fence, :confirmed} = ExecutionFence.confirm_termination(fence, token, context.session, evidence, now)
    {:ok, fence, :fenced} = ExecutionFence.FailedAttempt.record(fence, token, %{accepted_head: head, failure_evidence_ref: evidence_ref}, now)
    {:ok, fence, :prepared} = ExecutionFence.prepare_cleanup(fence, token, head, now, :failed)
    {:ok, fence} = ExecutionFence.record_cleanup_evidence(fence, token, head, evidence_ref, now)
    {:ok, fence, :cleaned} = ExecutionFence.cleanup(fence, token, head, now)
    {:ok, graph, _} = ResponsibilityGraph.release_runtime_lease(context.state.responsibility_graph, context.delegation, context.lease, now)
    {:ok, journal} = Journal.load(context.runtime.journal_path)
    [key] = Map.keys(journal.reservations)
    ack = %{reservation_state: "released", execution_capacity_state: "released", scope_state: "released", accepted_head: head}
    {:ok, journal} = Journal.put_cleanup_receipt(journal, key, "termination_confirmed", %{acknowledgement: ack})
    {:ok, journal} = Journal.put_cleanup_receipt(journal, key, "repository_cleanup_verified", %{acknowledgement: ack})
    assert :ok = Journal.save(context.runtime.journal_path, journal)
    %{context.state | execution_fence: fence, responsibility_graph: graph}
  end

  defp claim_input(state, issue) do
    Map.merge(state.work_package_runtime, %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      repository_ref: "openai/symphony",
      fence_state: state.execution_fence,
      responsibility_graph: state.responsibility_graph
    })
  end

  defp reservation(issue_id) do
    %{
      "projectionId" => "package-1",
      "reservationId" => "reservation",
      "reservationNonce" => "test-private-nonce",
      "issueId" => issue_id,
      "managedProjectProfileId" => "profile-test",
      "repositoryRef" => "openai/symphony",
      "scopeKeys" => ["repo:openai/symphony"]
    }
  end

  defp read_request(socket, buffer \\ "") do
    case :binary.split(buffer, "\r\n\r\n") do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length:\s*(\d+)/i, headers)
        length = String.to_integer(length)

        if byte_size(body) >= length do
          Jason.decode!(binary_part(body, 0, length))
        else
          {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
          read_request(socket, buffer <> data)
        end

      [_headers] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        read_request(socket, buffer <> data)
    end
  end

  defp reply(socket, body) do
    encoded = Jason.encode!(body)
    :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(encoded)}\r\nConnection: close\r\n\r\n" <> encoded)
    :gen_tcp.close(socket)
  end
end
