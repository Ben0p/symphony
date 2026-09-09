defmodule SymphonyElixir.WorkPackageClaim.Recovery do
  @moduledoc "Recovers current pre-spawn authority without new admission or fabricated worker observations."

  alias SymphonyElixir.{ExecutionFence, ResponsibilityGraph}
  alias SymphonyElixir.ManagedResponsibility.Admission
  alias SymphonyElixir.WorkPackageClaim.{Abandonment, Dispatch, Journal}

  @spec prepare(map(), map(), map(), map(), non_neg_integer() | nil, non_neg_integer()) ::
          :new | {:new, map()} | {:ok, map(), map(), map()} | {:error, term()}
  def prepare(runtime, fence, graph, issue, attempt, now_ms) do
    case fence.executions[issue.id] do
      nil ->
        new_without_claim(runtime, issue.id)

      %{status: :terminal, cleanup: :cleaned} = execution ->
        completed_claim(runtime, issue.id, execution)

      execution ->
        case Abandonment.check(runtime, fence, issue.id) do
          :authorized ->
            prepare_abandoned_claim(runtime, fence, graph, issue, attempt, now_ms)

          :missing ->
            prepare_existing_claim(runtime, fence, graph, issue, attempt, now_ms, execution)

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp prepare_existing_claim(runtime, fence, graph, issue, attempt, now_ms, execution) do
    if never_submitted?(execution),
      do: new_without_claim(runtime, issue.id),
      else: recover(runtime, fence, graph, issue, attempt, now_ms, execution)
  end

  defp prepare_abandoned_claim(runtime, fence, graph, issue, attempt, now_ms) do
    with %{entries: entries} <- runtime[:managed_delegations],
         entry when is_map(entry) <- Enum.find(entries, &(&1.issue_id == issue.id)),
         %{role: :responsible, status: :active, runtime_lease: nil, parent_delegation_id: parent} <- graph.delegations[entry.responsible.id],
         true <- parent == entry.accountable.id,
         {:ok, graph} <- reconcile_parent(graph, parent, now_ms),
         {:ok, graph} <- Admission.prepare(graph, fence, runtime.managed_delegations, issue, attempt, now_ms) do
      {:new, graph}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :claim_abandonment_responsibility_changed}
    end
  end

  @spec held?(map(), String.t()) :: boolean()
  def held?(fence, issue_id) do
    case fence.executions[issue_id] do
      %{status: :active, leases: leases} -> Enum.any?(leases, fn {_id, lease} -> lease.status == :active end)
      _ -> false
    end
  end

  @spec unstarted_claims(map() | nil, map()) :: {:ok, [map()]} | {:error, term()}
  def unstarted_claims(nil, _fence), do: {:ok, []}

  def unstarted_claims(runtime, fence) do
    case load_journal(runtime) do
      {:ok, journal} ->
        {:ok, Enum.filter(Map.values(journal.reservations), &unstarted?/1)}

      :missing ->
        missing_journal_claims(fence)

      {:error, _reason} = error ->
        error
    end
  end

  defp missing_journal_claims(fence) do
    if Enum.any?(fence.executions, fn {id, _execution} -> held?(fence, id) end),
      do: {:error, :claim_recovery_journal_missing},
      else: {:ok, []}
  end

  defp unstarted?(%{dispatch: %{phase: phase}}), do: phase in ["submitted", "confirmed", "blocked"]
  defp unstarted?(_reservation), do: false

  defp never_submitted?(%{status: :active, leases: leases}) when map_size(leases) > 0 do
    Enum.all?(leases, fn {_id, lease} ->
      lease.status == :released and lease[:release_reason] in [:claim_not_submitted, "claim_not_submitted"] and
        is_nil(lease[:supervisor_identity]) and lease.head == "unobserved"
    end)
  end

  defp never_submitted?(_execution), do: false

  defp new_without_claim(runtime, issue_id) do
    case load_journal(runtime) do
      :missing ->
        :new

      {:ok, journal} ->
        new_if_no_reservation(journal, issue_id)

      error ->
        error
    end
  end

  defp new_if_no_reservation(journal, issue_id) do
    if Enum.any?(journal.reservations, fn {_key, reservation} -> reservation.issue_id == issue_id end), do: {:error, :claim_exists_without_matching_fence}, else: :new
  end

  defp completed_claim(runtime, issue_id, execution) do
    with {:ok, journal} <- load_journal(runtime),
         key = reservation_key(runtime, issue_id, execution),
         %{generation: generation, cleanup_receipts: receipts} <- journal.reservations[key],
         true <- generation == execution.generation,
         %{acknowledgement: ack} <- receipts["repository_cleanup_verified"],
         true <-
           ack[:reservation_state] == "released" and ack[:scope_state] == "released" and
             ack[:accepted_head] == execution.terminal.accepted_head do
      :new
    else
      _ -> {:error, :claim_terminal_acknowledgement_required}
    end
  end

  defp reservation_key(runtime, issue_id, execution) do
    Journal.reservation_key(issue_id, runtime.managed_project_profile_id, execution.repository, execution.generation)
  end

  defp load_journal(%{journal_path: path}) when is_binary(path), do: Journal.load(path)
  defp load_journal(_runtime), do: :missing

  defp recover(runtime, fence, graph, issue, attempt, now_ms, execution) do
    with path when is_binary(path) <- runtime[:journal_path],
         {:ok, journal} <- Journal.load(path),
         {:ok, reservation} <- Dispatch.find(journal, issue.id, runtime.managed_project_profile_id, execution.repository, execution.generation),
         :ok <- Dispatch.retry_status(reservation, now_ms),
         input = Map.merge(runtime, %{repository_ref: execution.repository}),
         true <- same_authority?(reservation, runtime, input),
         {:ok, fence} <- ExecutionFence.reconcile_unstarted_claim(fence, reservation),
         lease = runtime_lease(reservation),
         {:ok, graph} <- reconcile_graph(graph, reservation.responsible_delegation_id, lease, now_ms),
         {:ok, graph} <- Admission.prepare(graph, fence, runtime[:managed_delegations], issue, attempt, now_ms),
         {:ok, delegation} <- ResponsibilityGraph.admission_delegation(graph, issue.id, issue.identifier, execution.repository),
         true <- delegation.id == reservation.responsible_delegation_id and delegation.runtime_lease == lease do
      {:ok, fence, graph, %{token: %{issue_id: issue.id, generation: reservation.generation}, session_id: reservation.session_id, delegation_id: delegation.id, runtime_lease: lease}}
    else
      {:error, _reason} = error -> error
      :missing -> {:error, :claim_recovery_journal_missing}
      _ -> {:error, :claim_recovery_not_ready}
    end
  end

  defp same_authority?(reservation, runtime, input) do
    reservation.runner_id == runtime.runner_id and
      reservation.dispatch.authority_digest == Dispatch.authority_digest(input)
  end

  defp reconcile_graph(graph, id, lease, now_ms) do
    case graph.delegations[id] do
      %{runtime_lease: ^lease, status: :active} ->
        {:ok, graph}

      %{runtime_lease: ^lease, status: :blocked, blocked_on: :restart_reconciliation, parent_delegation_id: parent} ->
        with {:ok, graph} <- reconcile_parent(graph, parent, now_ms),
             do: ResponsibilityGraph.reconcile_delegation(graph, id, lease, now_ms)

      _ ->
        {:error, :claim_responsibility_changed}
    end
  end

  defp reconcile_parent(graph, nil, _now_ms), do: {:ok, graph}

  defp reconcile_parent(graph, id, now_ms) do
    case graph.delegations[id] do
      %{role: :accountable, runtime_lease: nil, status: :active} ->
        {:ok, graph}

      %{role: :accountable, runtime_lease: nil, status: :blocked, blocked_on: :restart_reconciliation} ->
        ResponsibilityGraph.reconcile_delegation(graph, id, nil, now_ms)

      _ ->
        {:error, :claim_accountability_changed}
    end
  end

  defp runtime_lease(reservation) do
    %{
      issue_id: reservation.issue_id,
      repository: reservation.repository_ref,
      generation: reservation.generation,
      session_id: reservation.session_id,
      process_id: reservation.process_id
    }
  end
end
