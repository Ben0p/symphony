defmodule SymphonyElixir.ExecutionFence.FailedAttempt do
  @moduledoc "Records a terminated failed runtime attempt without inventing terminal tracker state."

  alias SymphonyElixir.ExecutionFence

  @failure_state "Failed attempt"
  @head ~r/\A[0-9a-f]{40}\z/
  @evidence_ref ~r/\Asha256:[0-9a-f]{64}\z/

  @spec record(map(), map(), map(), non_neg_integer()) ::
          {:ok, map(), :fenced | :already_fenced} | {:error, term()}
  def record(state, token, attrs, now) do
    with :ok <- ExecutionFence.validate(state),
         :ok <- valid_request(token, attrs, now),
         {:ok, execution} <- current_execution(state, token),
         :ok <- valid_transition(execution, attrs),
         :ok <- confirm_required_leases(state, token, execution, now) do
      ExecutionFence.fence(
        state,
        token,
        Map.put(attrs, :terminal_state, @failure_state),
        now
      )
    end
  end

  defp valid_request(%{issue_id: issue_id, generation: generation}, attrs, now)
       when is_binary(issue_id) and issue_id != "" and is_integer(generation) and generation > 0 and
              is_integer(now) and now >= 0 do
    valid_attributes(attrs)
  end

  defp valid_request(_token, _attrs, _now), do: {:error, :invalid_failed_attempt}

  defp valid_attributes(%{accepted_head: head, failure_evidence_ref: ref} = attrs)
       when map_size(attrs) == 2 and is_binary(head) and is_binary(ref) do
    if Regex.match?(@head, head) and Regex.match?(@evidence_ref, ref),
      do: :ok,
      else: {:error, :invalid_failure_attributes}
  end

  defp valid_attributes(_attrs), do: {:error, :invalid_failure_attributes}

  defp current_execution(state, %{issue_id: issue_id, generation: generation}) do
    case state.executions[issue_id] do
      %{generation: ^generation} = execution -> {:ok, execution}
      nil -> {:error, :execution_missing}
      _ -> {:error, :generation_mismatch}
    end
  end

  defp valid_transition(execution, attrs) do
    cond do
      execution.ownership != :reconciled ->
        {:error, :ownership_unreconciled}

      Map.get(execution, :termination_unconfirmed, false) ->
        {:error, :termination_unconfirmed}

      true ->
        valid_outcome_transition(execution, attrs)
    end
  end

  defp valid_outcome_transition(%{status: :active, terminal: nil, cleanup: :pending}, _attrs), do: :ok

  defp valid_outcome_transition(
         %{status: :terminal, cleanup: cleanup, terminal: %{state: @failure_state} = terminal},
         attrs
       )
       when cleanup in [:pending, :cleaned] do
    if terminal.accepted_head == attrs.accepted_head and
         Map.get(terminal, :failure_evidence_ref) == attrs.failure_evidence_ref,
       do: :ok,
       else: {:error, :terminal_conflict}
  end

  defp valid_outcome_transition(_execution, _attrs), do: {:error, :terminal_conflict}

  defp confirm_required_leases(state, token, execution, now) do
    leases = Map.values(execution.leases)

    if Enum.any?(leases, &(Map.get(&1, :role) == :worker and Map.get(&1, :termination_required, false))) do
      Enum.reduce_while(leases, :ok, fn lease, :ok -> lease_validation_result(state, token, lease, now) end)
    else
      {:error, :worker_termination_missing}
    end
  end

  defp lease_validation_result(state, token, lease, now) do
    case validate_lease(state, token, lease, now) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp validate_lease(state, token, lease, now) do
    cond do
      lease.status not in [:released, :expired] ->
        {:error, :lease_not_released}

      not Map.get(lease, :termination_required, false) ->
        :ok

      not valid_confirmation_time?(lease, now) ->
        {:error, :termination_not_already_confirmed}

      true ->
        case ExecutionFence.confirm_termination(state, token, lease.session_id, Map.get(lease, :termination_evidence), now) do
          {:ok, ^state, :already_confirmed} -> :ok
          _ -> {:error, :termination_not_already_confirmed}
        end
    end
  end

  defp valid_confirmation_time?(lease, now) do
    case Map.get(lease, :termination_confirmed_at_ms) do
      confirmed when is_integer(confirmed) and confirmed >= 0 and confirmed <= now -> true
      _ -> false
    end
  end
end
