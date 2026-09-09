defmodule SymphonyElixir.WorkPackageCleanupReceiptGenerationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ExecutionFence
  alias SymphonyElixir.WorkPackageClaim.Journal
  alias SymphonyElixir.WorkPackageCleanupReceipt

  @issue "issue-490"
  @profile "profile-490"
  @repository "hypergridau/symphony"
  @head "abc123"
  @event %{terminal_outcome: :completed, accepted_head: @head}

  for legacy <- [true, false] do
    @tag :tmp_dir
    test "generation 17 cleanup preserves history with legacy reservation #{legacy}", %{tmp_dir: tmp_dir} do
      fixture = fixture(Path.join(tmp_dir, "journal.json"), unquote(legacy))
      input = fixture.input
      options = [request_fun: request(fixture, :ack), now_fun: clock(0)]

      assert {:ok, %{scope_state: "held", generation: 17}} =
               WorkPackageCleanupReceipt.termination_confirmed(input, @event, options)

      assert_receipt(fixture, "termination_confirmed", true)
      assert_receive {:payload, %{"receiptKind" => "termination_confirmed"}}
      input = %{input | fence_state: cleaned_fence(input.fence_state, fixture.token)}
      event = Map.put(@event, :evidence_ref, "sha256:cleanup-490")
      options = [request_fun: request(fixture, :lost), now_fun: clock(1)]

      assert {:error, {:provider_request, :lost_response}} =
               WorkPackageCleanupReceipt.repository_cleanup_verified(input, event, options)

      assert_receive {:payload, first}
      assert_receipt(fixture, "repository_cleanup_verified", false)
      options = [request_fun: request(fixture, :replay), now_fun: clock(2)]

      assert {:ok, %{scope_state: "released", generation: 17} = result} =
               WorkPackageCleanupReceipt.repository_cleanup_verified(input, event, options)

      assert_receive {:payload, second}
      assert Map.drop(first, ["attestedAt", "signature"]) == Map.drop(second, ["attestedAt", "signature"])
      refute first["attestedAt"] == second["attestedAt"]
      refute first["signature"] == second["signature"]
      assert_receipt(fixture, "repository_cleanup_verified", true)
      options = [request_fun: &unexpected_request/2, now_fun: clock(3)]

      assert {:ok, ^result} =
               WorkPackageCleanupReceipt.repository_cleanup_verified(input, event, options)

      assert {:ok, journal} = Journal.load(input.journal_path)
      assert :ok = Journal.save(input.journal_path, journal)
      options = [request_fun: &unexpected_request/2, now_fun: clock(4)]

      assert {:ok, ^result} =
               WorkPackageCleanupReceipt.repository_cleanup_verified(input, event, options)

      assert_history(fixture)
      receipt_path = [:reservations, fixture.key, :cleanup_receipts, "repository_cleanup_verified", :generation]
      assert :ok = Journal.save(input.journal_path, put_in(journal, receipt_path, 1))
      before = File.read!(input.journal_path)
      options = [request_fun: &unexpected_request/2, now_fun: clock(5)]

      assert {:error, :cleanup_receipt_authority_mismatch} =
               WorkPackageCleanupReceipt.repository_cleanup_verified(input, event, options)

      assert File.read!(input.journal_path) == before
      assert_history(fixture)
    end
  end

  defp fixture(path, legacy?) do
    admission = %{issue_id: @issue, repository: @repository, branch: "codex/issue-490", worktree: "tmp/issue-490"}

    fence =
      Enum.reduce(1..16, ExecutionFence.new(), fn _, state ->
        {:ok, state, token} = ExecutionFence.admit(state, admission, 0)
        cleaned_fence(state, token)
      end)

    {:ok, fence, token} = ExecutionFence.admit(fence, admission, 0)

    worker =
      Map.merge(admission, %{generation: 17, role: :worker, session_id: "worker-490", process_id: "process-490", linear_state: "In Progress", pr_state: "OPEN", head: @head, last_heartbeat_at: 0})

    {:ok, fence, :registered} = ExecutionFence.register(fence, token, :worker, worker, 0)
    {:ok, fence, :released} = ExecutionFence.release(fence, token, "worker-490", :orchestrator_stop)
    evidence = %{session_id: "worker-490", process_id: "process-490", process_tree: :terminated, evidence_ref: "process-tree-check-490", observed_at_ms: 20}
    {:ok, fence, :confirmed} = ExecutionFence.confirm_termination(fence, token, "worker-490", evidence, 20)
    assert :ok = ExecutionFence.validate(fence)
    assert token.generation == 17

    reservation = %{
      issue_id: @issue,
      managed_project_profile_id: @profile,
      repository_ref: @repository,
      projection_id: "projection-490",
      reservation_id: "reservation-490",
      reservation_nonce: "nonce-490",
      scope_keys: ["repo:#{@repository}"],
      runner_id: "runner-490",
      generation: 17,
      session_id: "worker-490",
      process_id: "process-490",
      responsible_delegation_id: "delegation-490",
      execution_fence_token: "#{@issue}:17",
      runtime_lease_id: "worker-490"
    }

    key = Journal.reservation_key(@issue, @profile, @repository, 17)
    legacy_key = Journal.reservation_key(@issue, @profile, @repository)

    legacy =
      Map.merge(reservation, %{
        projection_id: "projection-old",
        reservation_id: "reservation-old",
        reservation_nonce: "nonce-old",
        generation: 1,
        session_id: "worker-old",
        process_id: "process-old",
        responsible_delegation_id: "delegation-old",
        execution_fence_token: "#{@issue}:1",
        runtime_lease_id: "worker-old"
      })

    {:ok, journal} = Journal.put(Journal.new(), key, reservation)
    {:ok, journal} = if legacy?, do: Journal.put(journal, legacy_key, legacy), else: {:ok, journal}
    assert :ok = Journal.save(path, journal)
    assert {:ok, persisted} = Journal.load(path)

    input = %{
      base_url: "http://provider.test",
      runner_token: "runner-token",
      attestation_key: "attestation-key",
      runner_id: "runner-490",
      managed_project_profile_id: @profile,
      issue_id: @issue,
      repository_ref: @repository,
      fence_state: fence,
      journal_path: path
    }

    %{input: input, token: token, key: key, historic: Map.delete(persisted.reservations, key)}
  end

  defp cleaned_fence(fence, token) do
    {:ok, fence, :fenced} = ExecutionFence.fence(fence, token, %{terminal_state: "Done", accepted_head: @head}, 30)
    {:ok, fence, :prepared} = ExecutionFence.prepare_cleanup(fence, token, @head, 31)
    {:ok, fence, :cleaned} = ExecutionFence.cleanup(fence, token, @head, 32)
    assert :ok = ExecutionFence.validate(fence)
    fence
  end

  defp request(fixture, mode) do
    parent = self()

    fn url, options ->
      assert url == "http://provider.test/runner/v1/work-packages/projection-490/cleanup-receipt"
      payload = Keyword.fetch!(options, :json)
      assert payload["generation"] == 17
      refute Map.has_key?(payload, "projectionId")
      assert_receipt(fixture, payload["receiptKind"], false)
      send(parent, {:payload, payload})

      if mode == :lost do
        {:error, :lost_response}
      else
        termination? = payload["receiptKind"] == "termination_confirmed"
        data = Map.take(payload, ["reservationId", "receiptId", "receiptKind", "generation", "evidenceRef", "acceptedHead"])

        data =
          Map.merge(data, %{
            "projectionId" => "projection-490",
            "executionCapacityState" => "released",
            "scopeState" => if(termination?, do: "held", else: "released"),
            "reservationState" => if(termination?, do: "claimed", else: "released"),
            "replayed" => mode == :replay
          })

        {:ok, %Req.Response{status: 200, body: %{"data" => data}}}
      end
    end
  end

  defp assert_receipt(fixture, kind, acknowledged?) do
    assert {:ok, journal} = Journal.load(fixture.input.journal_path)
    assert {:ok, %{generation: 17}} = Journal.cleanup_receipt(journal, fixture.key, kind)

    if acknowledged? do
      assert {:ok, %{generation: 17}} = Journal.cleanup_receipt_ack(journal, fixture.key, kind)
    else
      assert :missing = Journal.cleanup_receipt_ack(journal, fixture.key, kind)
    end

    assert_history(fixture)
  end

  defp assert_history(fixture) do
    assert {:ok, journal} = Journal.load(fixture.input.journal_path)
    assert Map.delete(journal.reservations, fixture.key) == fixture.historic
  end

  defp clock(minutes), do: fn -> DateTime.add(~U[2026-09-09 10:00:00.000Z], minutes * 60, :second) end
  defp unexpected_request(_, _), do: flunk("stored or invalid receipt must not send HTTP")
end
