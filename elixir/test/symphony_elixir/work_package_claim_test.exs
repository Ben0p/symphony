defmodule SymphonyElixir.WorkPackageClaimTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{ExecutionFence, ResponsibilityGraph, WorkPackageClaim}
  alias SymphonyElixir.WorkPackageClaim.Journal

  @repository "hypergridau/symphony"
  @issue_id "issue-349"
  @profile "profile-349"

  @canonical_json_fixture ~s({"contractVersion":"work-package-runtime-attestation.v1","runnerId":"runner-349","managedProjectProfileId":"profile-349","reservationId":"reservation-349","reservationNonce":"nonce-349","issueId":"issue-349","generation":1,"sessionId":"worker-349","processId":"process-349","responsibleDelegationId":"delegation-349","executionFenceToken":"issue-349:1","runtimeLeaseId":"worker-349","repositoryRef":"hypergridau/symphony","scopeKeys":["repo:hypergridau/symphony","work:349"],"attestedAt":"2026-09-06T10:00:00.000Z"})

  test "claims a reservation and replays the same journaled tuple after restart" do
    path = temp_path()
    on_exit(fn -> File.rm_rf(path) end)
    %{input: input, fence_state: fence, graph: graph} = authority_fixture(path)
    parent = self()

    first_request = fn url, options ->
      send(parent, {:request, url, options})

      if String.ends_with?(url, "/reservations/by-issue") do
        {:ok, response(%{"data" => reservation_payload()})}
      else
        {:error, :lost_response}
      end
    end

    assert {:error, {:provider_request, :lost_response}} = WorkPackageClaim.claim(input, request_fun: first_request, now_fun: fn -> ~U[2026-09-06 10:00:00.000Z] end)
    assert_receive {:request, reservation_url, reservation_options}
    assert String.ends_with?(reservation_url, "/reservations/by-issue")
    assert Keyword.get(reservation_options, :json) == %{issueId: @issue_id, managedProjectProfileId: @profile, repositoryRef: @repository}
    assert_receive {:request, claim_url, claim_options}
    assert String.ends_with?(claim_url, "/projection-349/claim")

    claim_payload = Keyword.fetch!(claim_options, :json).attestation
    assert claim_payload["generation"] == 1
    assert claim_payload["executionFenceToken"] == "#{@issue_id}:1"
    assert claim_payload["scopeKeys"] == ["repo:#{@repository}", "work:349"]

    if match?({:unix, _}, :os.type()) do
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    restarted_input = %{input | fence_state: fence, responsibility_graph: graph}

    second_request = fn url, options ->
      send(parent, {:replay_request, url, options})
      {:ok, response(%{"data" => claim_result_payload()})}
    end

    assert {:ok, second} = WorkPackageClaim.claim(restarted_input, request_fun: second_request, now_fun: fn -> ~U[2026-09-06 10:01:00.000Z] end)
    assert second.attestation.reservation_nonce == "nonce-349"
    assert_receive {:replay_request, replay_url, _replay_options}
    refute String.ends_with?(replay_url, "/reservations/by-issue")
  end

  test "fails closed for expired authority and malformed provider reservation" do
    path = temp_path()
    on_exit(fn -> File.rm_rf(path) end)
    %{input: input} = authority_fixture(path)

    reservation_fun = fn url, _options ->
      if String.ends_with?(url, "/reservations/by-issue") do
        {:ok, response(%{"data" => %{"projectionId" => "p", "reservationId" => "r"}})}
      else
        {:ok, response(%{"data" => %{}})}
      end
    end

    assert {:error, {:missing_reservation_field, "reservationNonce"}} =
             WorkPackageClaim.claim(input, request_fun: reservation_fun)

    expired_graph = put_in(input.responsibility_graph, [:delegations, "delegation-349", :expires_at_ms], 1)

    assert {:error, :runtime_lease_mismatch} =
             WorkPackageClaim.claim(
               %{input | responsibility_graph: expired_graph},
               request_fun: reservation_fun
             )

    assert {:ok, canonical} =
             WorkPackageClaim.canonical_json(attestation_for_test())

    assert canonical == @canonical_json_fixture

    assert {:ok, signature} = WorkPackageClaim.sign(attestation_for_test(), "attestation-key")
    assert signature == "eYASgI7yqAih8J9N1Noj0r8Ap8X3H3tVgi__MnwwQkg"
  end

  test "rejects corrupt journals, profile mismatches, malformed claims, and HTTP errors" do
    path = temp_path()
    on_exit(fn -> File.rm_rf(path) end)
    %{input: input} = authority_fixture(path)

    File.write!(path, "{}")
    assert {:error, {:invalid_journal, _reason}} = WorkPackageClaim.claim(input)
    File.rm!(path)

    wrong_profile = fn url, _options ->
      if String.ends_with?(url, "/reservations/by-issue") do
        {:ok, response(%{"data" => %{reservation_payload() | "managedProjectProfileId" => "profile-other"}})}
      else
        {:ok, response(%{"data" => claim_result_payload()})}
      end
    end

    assert {:error, :reservation_scope_mismatch} =
             WorkPackageClaim.claim(input, request_fun: wrong_profile)

    malformed_claim = fn url, _options ->
      if String.ends_with?(url, "/reservations/by-issue") do
        {:ok, response(%{"data" => reservation_payload()})}
      else
        {:ok, response(%{"data" => %{}})}
      end
    end

    assert {:error, :invalid_claim_result} =
             WorkPackageClaim.claim(input, request_fun: malformed_claim)

    provider_error = fn _url, _options -> {:ok, response(%{"error" => "unavailable"}, 503)} end

    assert {:error, {:provider_status, 503}} =
             WorkPackageClaim.claim(input, request_fun: provider_error)

    assert {:ok, journal} = Journal.load(path)
    assert map_size(journal.reservations) == 1
    [{key, reservation}] = Map.to_list(journal.reservations)
    {:ok, corrupted_journal} = Journal.put(journal, key, %{reservation | generation: 2})
    assert :ok = Journal.save(path, corrupted_journal)

    assert {:error, :reservation_authority_mismatch} =
             WorkPackageClaim.claim(input, request_fun: provider_error)
  end

  defp authority_fixture(path) do
    fence = ExecutionFence.new()

    {:ok, admitted, token} =
      ExecutionFence.admit(fence, %{issue_id: @issue_id, repository: @repository, branch: "hgs-349", worktree: "tmp"}, 0)

    {:ok, fence_state, :registered} =
      ExecutionFence.register(
        admitted,
        token,
        :worker,
        %{
          session_id: "worker-349",
          process_id: "process-349",
          branch: "hgs-349",
          worktree: "tmp",
          linear_state: "In Progress",
          pr_state: "none",
          head: "unobserved",
          last_heartbeat_at: 0
        },
        0
      )

    lease = %{
      issue_id: @issue_id,
      repository: @repository,
      generation: 1,
      session_id: "worker-349",
      process_id: "process-349"
    }

    scope = %{
      company_id: "hypergrid",
      objective_id: "objective",
      initiative_id: "initiative",
      project_id: "project",
      work_package_id: "package",
      issue_id: @issue_id,
      repository: @repository,
      paths: [],
      modules: [],
      environments: ["local"],
      actions: [
        :read,
        :observe,
        :delegate,
        :reconcile,
        :edit,
        :commit,
        :push,
        :state_mutation,
        :cleanup,
        :review,
        :report
      ]
    }

    authority = %{
      class: :routine_engineering,
      capabilities: scope.actions,
      environments: ["local"]
    }

    budget = %{model: "luna", effort: :high, max_tokens: 1000, max_children: 1}

    {:ok, owner_graph, _} =
      ResponsibilityGraph.delegate(
        ResponsibilityGraph.new(),
        delegation("owner", :accountable, scope, authority, budget),
        0
      )

    {:ok, child_graph, _} =
      ResponsibilityGraph.delegate(
        owner_graph,
        delegation(
          "delegation-349",
          :responsible,
          scope,
          authority,
          budget,
          parent_delegation_id: "owner"
        ),
        0
      )

    {:ok, graph} = ResponsibilityGraph.bind_runtime_lease(child_graph, "delegation-349", lease, 0)

    input = %{
      base_url: "http://provider.test",
      runner_token: "runner-token",
      attestation_key: "attestation-key",
      runner_id: "runner-349",
      managed_project_profile_id: @profile,
      issue_id: @issue_id,
      issue_identifier: "HGS-349",
      repository_ref: @repository,
      fence_state: fence_state,
      responsibility_graph: graph,
      journal_path: path
    }

    %{input: input, fence_state: fence_state, graph: graph}
  end

  defp delegation(id, role, scope, authority, budget, extras \\ []) do
    Map.merge(
      %{
        id: id,
        parent_delegation_id: nil,
        role: role,
        actor_id: id,
        scope: scope,
        authority: authority,
        budget: budget,
        runtime_lease: nil,
        expires_at_ms: 2_000_000_000_000,
        expected_deliverable: "adapter",
        expected_evidence: "tests",
        return_to_parent: %{owner_id: "owner", contract: "evidence"}
      },
      Map.new(extras)
    )
  end

  defp reservation_payload do
    %{
      "projectionId" => "projection-349",
      "reservationId" => "reservation-349",
      "reservationNonce" => "nonce-349",
      "issueId" => @issue_id,
      "managedProjectProfileId" => @profile,
      "repositoryRef" => @repository,
      "scopeKeys" => ["work:349", "repo:#{@repository}"]
    }
  end

  defp claim_result_payload do
    %{
      "projectionId" => "projection-349",
      "projectionState" => "active",
      "mutationState" => "applied",
      "claimEvidence" => %{
        "responsibleDelegationId" => "delegation-349",
        "executionFenceToken" => "#{@issue_id}:1",
        "runtimeLeaseId" => "worker-349"
      }
    }
  end

  defp attestation_for_test do
    %{
      contract_version: "work-package-runtime-attestation.v1",
      runner_id: "runner-349",
      managed_project_profile_id: @profile,
      reservation_id: "reservation-349",
      reservation_nonce: "nonce-349",
      issue_id: @issue_id,
      generation: 1,
      session_id: "worker-349",
      process_id: "process-349",
      responsible_delegation_id: "delegation-349",
      execution_fence_token: "#{@issue_id}:1",
      runtime_lease_id: "worker-349",
      repository_ref: @repository,
      scope_keys: ["work:349", "repo:#{@repository}"],
      attested_at: "2026-09-06T10:00:00.000Z"
    }
  end

  defp response(body, status \\ 200), do: %Req.Response{status: status, body: body}

  defp temp_path, do: Path.join(System.tmp_dir!(), "symphony-work-package-#{System.unique_integer([:positive])}.json")
end
