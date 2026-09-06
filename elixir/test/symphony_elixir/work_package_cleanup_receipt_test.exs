defmodule SymphonyElixir.WorkPackageCleanupReceiptTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ExecutionFence
  alias SymphonyElixir.WorkPackageClaim.Journal
  alias SymphonyElixir.WorkPackageCleanupReceipt

  @issue "issue-350"
  @profile "profile-350"
  @repository "hypergridau/symphony"
  @runner "runner-350"
  @reservation_key "issue-350\u0000profile-350\u0000hypergridau/symphony"

  test "posts a signed termination receipt from the persisted generation tuple" do
    %{input: input, token: token} = fixture()
    {:ok, state, :released} = ExecutionFence.release(input.fence_state, token, "worker-350", :orchestrator_stop)

    evidence = termination_evidence()
    {:ok, state, :confirmed} = ExecutionFence.confirm_termination(state, token, "worker-350", evidence, 20)
    input = %{input | fence_state: state}
    parent = self()

    request_fun = fn url, options ->
      send(parent, {:request, url, options})
      payload = Keyword.fetch!(options, :json)

      {:ok,
       response(%{
         "projectionId" => "projection-350",
         "reservationId" => payload["reservationId"],
         "receiptId" => payload["receiptId"],
         "receiptKind" => "termination_confirmed",
         "executionCapacityState" => "released",
         "scopeState" => "held",
         "reservationState" => "claimed",
         "generation" => 1,
         "evidenceRef" => payload["evidenceRef"],
         "acceptedHead" => payload["acceptedHead"],
         "replayed" => false
       })}
    end

    assert {:ok, result} =
             WorkPackageCleanupReceipt.termination_confirmed(
               input,
               %{terminal_outcome: :completed, accepted_head: "abc123"},
               request_fun: request_fun,
               now_fun: fn -> ~U[2026-09-06 10:00:00.000Z] end
             )

    assert result.projection_id == "projection-350"
    assert result.reservation_id == "reservation-350"
    assert is_binary(result.receipt_id)
    assert result.receipt_kind == "termination_confirmed"
    assert result.execution_capacity_state == "released"
    assert result.scope_state == "held"
    assert result.reservation_state == "claimed"
    assert result.generation == 1
    assert result.evidence_ref == "process-tree-check-350"
    assert result.accepted_head == "abc123"
    assert result.replayed == false

    assert_receive {:request, url, options}
    assert url == "http://provider.test/runner/v1/work-packages/projection-350/cleanup-receipt"

    assert Keyword.get(options, :headers) == [
             {"authorization", "Bearer runner-token"},
             {"content-type", "application/json"}
           ]

    payload = Keyword.fetch!(options, :json)

    assert Map.keys(payload) |> Enum.sort() == [
             "acceptedHead",
             "attestedAt",
             "contractVersion",
             "evidenceRef",
             "executionFenceToken",
             "generation",
             "issueId",
             "managedProjectProfileId",
             "observedAt",
             "processId",
             "receiptId",
             "receiptKind",
             "repositoryRef",
             "reservationId",
             "reservationNonce",
             "responsibleDelegationId",
             "runnerId",
             "runtimeLeaseId",
             "scopeKeys",
             "sessionId",
             "signature",
             "terminalOutcome"
           ]

    assert payload["executionFenceToken"] == "#{@issue}:1"
    assert payload["runtimeLeaseId"] == payload["sessionId"]
    assert payload["scopeKeys"] == ["repo:#{@repository}", "work:350"]

    assert {:ok, replayed_result} =
             WorkPackageCleanupReceipt.termination_confirmed(
               input,
               %{terminal_outcome: :completed, accepted_head: "abc123"},
               request_fun: fn _url, _options -> flunk("an acknowledged receipt must not be resent") end,
               now_fun: fn -> ~U[2026-09-06 10:01:00.000Z] end
             )

    assert replayed_result == result
    assert {:ok, journal} = Journal.load(input.journal_path)
    assert {:ok, acknowledgement} = Journal.cleanup_receipt_ack(journal, @reservation_key, "termination_confirmed")
    assert acknowledgement.receipt_id == result.receipt_id
    assert acknowledgement.scope_state == "held"

    {:ok, invalid_journal} =
      Journal.put_cleanup_receipt_ack(
        journal,
        @reservation_key,
        "termination_confirmed",
        %{scope_state: "held"}
      )

    assert :ok = Journal.save(input.journal_path, invalid_journal)

    assert {:error, :invalid_cleanup_acknowledgement} =
             WorkPackageCleanupReceipt.termination_confirmed(
               input,
               %{terminal_outcome: :completed, accepted_head: "abc123"},
               request_fun: fn _url, _options -> flunk("a malformed acknowledgement must fail closed") end
             )
  end

  test "journals the semantic receipt before a lost response and refreshes only freshness fields" do
    %{input: input, token: token, journal_path: journal_path} = fixture()
    {:ok, state, :released} = ExecutionFence.release(input.fence_state, token, "worker-350", :orchestrator_stop)
    {:ok, state, :confirmed} = ExecutionFence.confirm_termination(state, token, "worker-350", termination_evidence(), 20)
    input = %{input | fence_state: state}
    parent = self()

    first_request = fn _url, options ->
      send(parent, {:payload, Keyword.fetch!(options, :json)})
      {:error, :lost_response}
    end

    assert {:error, {:provider_request, :lost_response}} =
             WorkPackageCleanupReceipt.termination_confirmed(
               input,
               %{terminal_outcome: :completed, accepted_head: "abc123"},
               request_fun: first_request,
               now_fun: fn -> ~U[2026-09-06 10:00:00.000Z] end
             )

    assert_receive {:payload, first_payload}
    assert {:ok, journal} = Journal.load(journal_path)
    assert {:ok, semantic} = Journal.cleanup_receipt(journal, @reservation_key, "termination_confirmed")
    assert semantic.receipt_id == first_payload["receiptId"]
    refute Map.has_key?(semantic, :signature)
    refute Map.has_key?(semantic, :attested_at)

    second_request = fn _url, options ->
      send(parent, {:payload, Keyword.fetch!(options, :json)})
      payload = Keyword.fetch!(options, :json)

      {:ok,
       response(%{
         "projectionId" => "projection-350",
         "reservationId" => "reservation-350",
         "receiptId" => payload["receiptId"],
         "receiptKind" => "termination_confirmed",
         "executionCapacityState" => "released",
         "scopeState" => "held",
         "reservationState" => "claimed",
         "generation" => 1,
         "evidenceRef" => payload["evidenceRef"],
         "acceptedHead" => payload["acceptedHead"],
         "replayed" => true
       })}
    end

    assert {:ok, %{replayed: true}} =
             WorkPackageCleanupReceipt.termination_confirmed(
               input,
               %{terminal_outcome: :completed, accepted_head: "abc123"},
               request_fun: second_request,
               now_fun: fn -> ~U[2026-09-06 10:01:00.000Z] end
             )

    assert_receive {:payload, second_payload}
    assert second_payload["receiptId"] == first_payload["receiptId"]
    assert second_payload["observedAt"] == first_payload["observedAt"]
    assert second_payload["evidenceRef"] == first_payload["evidenceRef"]
    assert second_payload["acceptedHead"] == first_payload["acceptedHead"]
    refute second_payload["attestedAt"] == first_payload["attestedAt"]
    refute second_payload["signature"] == first_payload["signature"]

    assert {:ok, %{replayed: true} = replayed_result} =
             WorkPackageCleanupReceipt.termination_confirmed(
               input,
               %{terminal_outcome: :completed, accepted_head: "abc123"},
               request_fun: fn _url, _options -> flunk("the persisted provider acknowledgement must be reused") end,
               now_fun: fn -> ~U[2026-09-06 10:02:00.000Z] end
             )

    assert replayed_result.receipt_id == second_payload["receiptId"]
  end

  test "rejects cleanup receipts before local termination and filesystem verification" do
    %{input: input, token: token} = fixture()

    assert {:error, :termination_not_confirmed} =
             WorkPackageCleanupReceipt.termination_confirmed(
               input,
               %{terminal_outcome: :completed, accepted_head: "abc123"},
               request_fun: fn _url, _options -> flunk("provider must not be called") end
             )

    {:ok, state, :fenced} = ExecutionFence.fence(input.fence_state, token, terminal(), 30)
    input = %{input | fence_state: state}

    assert {:error, :repository_cleanup_not_verified} =
             WorkPackageCleanupReceipt.repository_cleanup_verified(
               input,
               %{terminal_outcome: :completed, accepted_head: "abc123", evidence_ref: "sha256:cleanup"},
               request_fun: fn _url, _options -> flunk("provider must not be called") end
             )
  end

  test "canonical JSON follows the provider cleanup receipt tuple order" do
    receipt = %{
      contract_version: "work-package-cleanup-receipt.v1",
      receipt_id: "receipt-350",
      receipt_kind: "termination_confirmed",
      terminal_outcome: "completed",
      observed_at: "2026-09-06T10:00:00.000Z",
      evidence_ref: "process-tree-check-350",
      accepted_head: "abc123",
      runner_id: @runner,
      managed_project_profile_id: @profile,
      reservation_id: "reservation-350",
      reservation_nonce: "nonce-350",
      issue_id: @issue,
      generation: 1,
      session_id: "worker-350",
      process_id: "process-350",
      responsible_delegation_id: "delegation-350",
      execution_fence_token: "#{@issue}:1",
      runtime_lease_id: "worker-350",
      repository_ref: @repository,
      scope_keys: ["work:350", "repo:#{@repository}"],
      attested_at: "2026-09-06T10:00:00.000Z"
    }

    assert {:ok, canonical} = WorkPackageCleanupReceipt.canonical_json(receipt)

    assert canonical ==
             ~s({"contractVersion":"work-package-cleanup-receipt.v1","receiptId":"receipt-350","receiptKind":"termination_confirmed","terminalOutcome":"completed","observedAt":"2026-09-06T10:00:00.000Z","evidenceRef":"process-tree-check-350","acceptedHead":"abc123","runnerId":"runner-350","managedProjectProfileId":"profile-350","reservationId":"reservation-350","reservationNonce":"nonce-350","issueId":"issue-350","generation":1,"sessionId":"worker-350","processId":"process-350","responsibleDelegationId":"delegation-350","executionFenceToken":"issue-350:1","runtimeLeaseId":"worker-350","repositoryRef":"hypergridau/symphony","scopeKeys":["repo:hypergridau/symphony","work:350"],"attestedAt":"2026-09-06T10:00:00.000Z"})
  end

  test "releases repository scope only after termination and verified filesystem cleanup" do
    %{input: input, token: token} = fixture()
    {:ok, state, :released} = ExecutionFence.release(input.fence_state, token, "worker-350", :orchestrator_stop)
    {:ok, state, :confirmed} = ExecutionFence.confirm_termination(state, token, "worker-350", termination_evidence(), 20)
    input = %{input | fence_state: state}

    request = fn _url, options ->
      payload = Keyword.fetch!(options, :json)

      {:ok,
       response(%{
         "projectionId" => "projection-350",
         "reservationId" => "reservation-350",
         "receiptId" => payload["receiptId"],
         "receiptKind" => payload["receiptKind"],
         "executionCapacityState" => "released",
         "scopeState" => if(payload["receiptKind"] == "termination_confirmed", do: "held", else: "released"),
         "reservationState" => if(payload["receiptKind"] == "termination_confirmed", do: "claimed", else: "released"),
         "generation" => 1,
         "evidenceRef" => payload["evidenceRef"],
         "acceptedHead" => payload["acceptedHead"],
         "replayed" => false
       })}
    end

    assert {:ok, %{scope_state: "held"}} =
             WorkPackageCleanupReceipt.termination_confirmed(
               input,
               %{terminal_outcome: :completed, accepted_head: "abc123"},
               request_fun: request,
               now_fun: fn -> ~U[2026-09-06 10:00:00.000Z] end
             )

    {:ok, state, :fenced} = ExecutionFence.fence(state, token, terminal(), 30)
    {:ok, state, :prepared} = ExecutionFence.prepare_cleanup(state, token, "abc123", 31)
    {:ok, state, :cleaned} = ExecutionFence.cleanup(state, token, "abc123", 32)
    input = %{input | fence_state: state}

    assert {:ok, result} =
             WorkPackageCleanupReceipt.repository_cleanup_verified(
               input,
               %{terminal_outcome: :completed, accepted_head: "abc123", evidence_ref: "sha256:cleanup-350"},
               request_fun: request,
               now_fun: fn -> ~U[2026-09-06 10:01:00.000Z] end
             )

    assert result.receipt_kind == "repository_cleanup_verified"
    assert result.execution_capacity_state == "released"
    assert result.scope_state == "released"
    assert result.reservation_state == "released"
  end

  defp fixture do
    journal_path = Path.join(System.tmp_dir!(), "symphony-cleanup-receipt-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(journal_path) end)

    admission = %{issue_id: @issue, repository: @repository, branch: "codex/issue-350", worktree: "tmp/issue-350"}
    {:ok, fence, token} = ExecutionFence.admit(ExecutionFence.new(), admission, 0)

    session =
      Map.merge(admission, %{
        generation: 1,
        role: :worker,
        session_id: "worker-350",
        process_id: "process-350",
        linear_state: "In Progress",
        pr_state: "OPEN",
        head: "abc123",
        last_heartbeat_at: 0
      })

    {:ok, fence, :registered} = ExecutionFence.register(fence, token, :worker, session, 0)

    reservation = %{
      issue_id: @issue,
      managed_project_profile_id: @profile,
      repository_ref: @repository,
      projection_id: "projection-350",
      reservation_id: "reservation-350",
      reservation_nonce: "nonce-350",
      scope_keys: ["work:350", "repo:#{@repository}"],
      runner_id: @runner,
      generation: 1,
      session_id: "worker-350",
      process_id: "process-350",
      responsible_delegation_id: "delegation-350",
      execution_fence_token: "#{@issue}:1",
      runtime_lease_id: "worker-350"
    }

    {:ok, journal} = Journal.put(Journal.new(), @reservation_key, reservation)
    assert :ok = Journal.save(journal_path, journal)

    input = %{
      base_url: "http://provider.test",
      runner_token: "runner-token",
      attestation_key: "attestation-key",
      runner_id: @runner,
      managed_project_profile_id: @profile,
      issue_id: @issue,
      repository_ref: @repository,
      fence_state: fence,
      journal_path: journal_path
    }

    %{input: input, token: token, journal_path: journal_path}
  end

  defp termination_evidence do
    %{
      session_id: "worker-350",
      process_id: "process-350",
      process_tree: :terminated,
      evidence_ref: "process-tree-check-350",
      observed_at_ms: 20
    }
  end

  defp terminal do
    %{terminal_state: "Done", accepted_head: "abc123"}
  end

  defp response(data), do: %Req.Response{status: 200, body: %{"data" => data}}
end
