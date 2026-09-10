defmodule SymphonyElixir.ResponsibilityGraph.ReviewCompletion do
  @moduledoc "Completes an attested review handoff without reopening admission after restart."

  alias SymphonyElixir.{ExecutionFence, ResponsibilityGraph, ReviewHandoff}
  @identity [:issue_id, :repository, :generation, :session_id, :process_id]

  @spec complete(map(), map(), map(), map(), non_neg_integer()) :: {:ok, map(), map()} | {:error, term()}
  def complete(graph, fence, entry, evidence, now_ms) do
    with %{execution_token: token, review_reservation: reservation, responsibility_delegation_id: id} <- entry,
         true <- is_map(reservation),
         %{accepted_head: head, merge_identity: merge} <- evidence,
         :ok <- ExecutionFence.validate_cleanup(fence, token, head),
         execution when is_map(execution) <- get_in(fence, [:executions, token.issue_id]),
         {:ok, current_entry} <- ReviewHandoff.entry(execution, Map.get(entry, :issue)),
         true <- Map.take(entry, Map.keys(current_entry)) == current_entry,
         lease when is_map(lease) <- execution.leases[entry.execution_session_id],
         :ok <- ResponsibilityGraph.validate(graph),
         delegation when is_map(delegation) <- graph.delegations[id],
         true <- valid_identity?(delegation, lease, reservation, execution, entry),
         true <- execution.terminal.merge_identity == merge do
      complete_delegation(graph, delegation, evidence, now_ms)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :review_completion_identity_mismatch}
    end
  end

  defp valid_identity?(delegation, lease, reservation, execution, entry) do
    identity = Map.take(lease, @identity)

    expected = %{
      issue_id: execution.issue_id,
      repository: execution.repository,
      generation: execution.generation,
      session_id: Map.get(reservation, :session_id),
      process_id: Map.get(reservation, :process_id)
    }

    identity == expected and delegation.role == :responsible and
      delegation.id == Map.get(reservation, :responsible_delegation_id) and
      delegation.scope.repository == execution.repository and
      delegation.scope.issue_id in [execution.issue_id, entry.issue.identifier] and
      (is_nil(delegation.runtime_lease) or Map.take(delegation.runtime_lease, @identity) == expected)
  end

  defp complete_delegation(graph, %{status: :completed} = delegation, evidence, _now_ms) do
    if evidence_equal?(delegation.terminal_evidence, evidence) do
      {:ok, graph, %{}}
    else
      {:error, :review_completion_evidence_changed}
    end
  end

  defp complete_delegation(graph, %{status: :active} = delegation, evidence, now_ms),
    do: complete_leaf(graph, delegation.id, evidence, now_ms)

  defp complete_delegation(graph, %{status: :blocked, blocked_on: :restart_reconciliation} = delegation, evidence, now_ms) do
    # This temporary value is never persisted or emitted as an activation event.
    temporary = put_in(graph, [:delegations, delegation.id], %{delegation | status: :active, blocked_on: nil})
    complete_leaf(temporary, delegation.id, evidence, now_ms)
  end

  defp complete_delegation(_, _, _, _), do: {:error, :review_completion_not_eligible}

  defp complete_leaf(graph, id, evidence, now_ms) do
    with {:ok, completed, impact} <- ResponsibilityGraph.complete(graph, id, evidence, now_ms),
         true <- Map.delete(completed.delegations, id) == Map.delete(graph.delegations, id) do
      {:ok, completed, impact}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :review_completion_has_active_descendants}
    end
  end

  defp evidence_equal?(retained, evidence) when is_map(retained) do
    Enum.all?([:terminal_state, :accepted_head, :merge_identity], fn key ->
      Map.get(retained, key, Map.get(retained, Atom.to_string(key))) == evidence[key]
    end)
  end

  defp evidence_equal?(_, _), do: false
end
