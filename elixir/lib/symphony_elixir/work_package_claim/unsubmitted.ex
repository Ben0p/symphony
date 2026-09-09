defmodule SymphonyElixir.WorkPackageClaim.Unsubmitted do
  @moduledoc "Distinguishes current claim uncertainty from retained historical attempts."

  alias SymphonyElixir.{ExecutionFence, ResponsibilityGraph}
  alias SymphonyElixir.WorkPackageClaim.Journal

  @spec claim_may_exist?(map(), map(), String.t()) :: boolean()
  def claim_may_exist?(runtime, fence, issue_id) do
    case current_claim(runtime, fence.executions[issue_id]) do
      :absent -> false
      :missing -> false
      _ -> true
    end
  end

  @spec prepare(map(), map(), map(), map(), non_neg_integer()) ::
          :submitted | {:new, map(), map()} | {:error, term()}
  def prepare(runtime, fence, graph, execution, now_ms) do
    case current_claim(runtime, execution) do
      :present -> :submitted
      :absent -> release(runtime, fence, graph, execution, now_ms)
      :missing -> prepare_missing(runtime, fence, graph, execution, now_ms)
      {:error, _reason} = error -> error
    end
  end

  defp prepare_missing(runtime, fence, graph, execution, now_ms) do
    case Map.values(execution.leases) do
      [%{status: :released, release_reason: reason}] when reason in [:claim_not_submitted, "claim_not_submitted"] ->
        release(runtime, fence, graph, execution, now_ms)

      _ ->
        {:error, :claim_recovery_journal_missing}
    end
  end

  defp current_claim(runtime, %{issue_id: issue_id, repository: repository, generation: generation}) do
    with profile when is_binary(profile) and profile != "" <- runtime[:managed_project_profile_id],
         path when is_binary(path) and path != "" <- runtime[:journal_path] do
      case Journal.load(path) do
        {:ok, journal} -> reservation_status(journal, issue_id, profile, repository, generation)
        :missing -> :missing
        {:error, _reason} = error -> error
      end
    else
      _ -> {:error, :claim_recovery_identity_missing}
    end
  end

  defp current_claim(_runtime, _execution), do: {:error, :claim_recovery_identity_missing}

  defp reservation_status(journal, issue_id, profile, repository, generation) do
    current = Enum.filter(journal.reservations, fn {_key, r} -> r.issue_id == issue_id and r.generation >= generation end)
    key = Journal.reservation_key(issue_id, profile, repository, generation)

    case current do
      [] ->
        :absent

      [{^key, %{managed_project_profile_id: ^profile, repository_ref: ^repository, generation: ^generation}}] ->
        :present

      _ ->
        {:error, :claim_recovery_identity_conflict}
    end
  end

  defp release(runtime, fence, graph, execution, now_ms) do
    token = %{issue_id: execution.issue_id, generation: execution.generation}

    with :ok <- ExecutionFence.validate(fence),
         :ok <- ResponsibilityGraph.validate(graph),
         [worker] <- Map.values(execution.leases),
         {:ok, released_fence} <- ExecutionFence.release_unsubmitted_claim(fence, token, worker.session_id),
         %{entries: entries} <- runtime[:managed_delegations],
         entry when is_map(entry) <- Enum.find(entries, &(&1.issue_id == execution.issue_id)),
         %{role: :responsible, parent_delegation_id: parent} <- graph.delegations[entry.responsible.id],
         true <- parent == entry.accountable.id,
         lease = Map.take(worker, [:issue_id, :repository, :generation, :session_id, :process_id]),
         {:ok, graph} <- reconcile_parent(graph, parent, now_ms),
         {:ok, graph} <- reconcile_responsible(graph, entry.responsible.id, lease, now_ms),
         {:ok, graph, _} <- ResponsibilityGraph.release_runtime_lease(graph, entry.responsible.id, lease, now_ms) do
      {:new, released_fence, graph}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :unsubmitted_claim_responsibility_changed}
    end
  end

  defp reconcile_parent(graph, parent, now_ms) do
    case graph.delegations[parent] do
      %{role: :accountable, runtime_lease: nil, status: :active} ->
        {:ok, graph}

      %{role: :accountable, runtime_lease: nil, status: :blocked, blocked_on: :restart_reconciliation} ->
        ResponsibilityGraph.reconcile_delegation(graph, parent, nil, now_ms)

      _ ->
        {:error, :claim_accountability_changed}
    end
  end

  defp reconcile_responsible(graph, id, lease, now_ms) do
    case graph.delegations[id] do
      %{status: :active, runtime_lease: current} when current == lease or is_nil(current) ->
        {:ok, graph}

      %{status: :blocked, blocked_on: :restart_reconciliation, runtime_lease: current}
      when current == lease or is_nil(current) ->
        ResponsibilityGraph.reconcile_delegation(graph, id, current, now_ms)

      _ ->
        {:error, :claim_responsibility_changed}
    end
  end
end
