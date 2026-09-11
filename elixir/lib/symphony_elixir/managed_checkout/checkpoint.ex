defmodule SymphonyElixir.ManagedCheckout.Checkpoint do
  @moduledoc false

  alias SymphonyElixir.{ExecutionFence, ResponsibilityGraph}

  @identity_keys [:issue_id, :generation, :repository, :worktree, :branch]
  @checkpoint_keys [:kind, :sequence, :previous_head, :head, :tree_changed, :identity]

  @spec accept(map(), term(), pid(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def accept(%{running: running, execution_fence: %{executions: executions}} = state, issue_id, sender, checkpoint, %DateTime{} = now)
      when is_map(running) and is_map(executions) and is_pid(sender) and is_map(checkpoint) do
    with %{pid: ^sender} = entry <- Map.get(running, issue_id),
         execution when is_map(execution) <- Map.get(executions, issue_id),
         {:ok, identity} <- identity(execution, entry, issue_id),
         :ok <- validate(entry, identity, checkpoint),
         :ok <- authorized(state, entry) do
      {:ok, transition(entry, checkpoint, now)}
    else
      {:error, _} = error -> error
      _ -> {:error, :checkout_progress_sender_rejected}
    end
  end

  def accept(_state, _issue_id, _sender, _checkpoint, _now), do: {:error, :checkout_progress_input_invalid}

  defp identity(execution, entry, issue_id) do
    identity = execution |> Map.take(@identity_keys) |> Map.put(:session_id, Map.get(entry, :execution_session_id))

    if map_size(identity) == 6 and Map.get(identity, :issue_id) == issue_id and
         is_binary(identity.session_id) and identity.session_id != "" and
         Map.get(entry, :execution_token) == Map.take(identity, [:issue_id, :generation]) do
      {:ok, identity}
    else
      {:error, :checkout_progress_identity_unavailable}
    end
  end

  defp validate(entry, identity, checkpoint) do
    with true <- Map.keys(checkpoint) |> Enum.sort() == Enum.sort(@checkpoint_keys),
         true <- checkpoint.identity == identity,
         true <- valid_head?(checkpoint.head),
         true <- valid_sequence?(entry, checkpoint),
         true <- valid_kind?(checkpoint.kind, checkpoint.tree_changed),
         true <- valid_workspace?(entry, identity.worktree, checkpoint.kind),
         total when is_integer(total) and total >= 0 <- Map.get(entry, :codex_total_tokens) do
      :ok
    else
      _ -> {:error, :checkout_progress_checkpoint_rejected}
    end
  end

  defp valid_sequence?(entry, %{kind: :baseline, sequence: 0, previous_head: nil}) do
    is_nil(Map.get(entry, :checkout_head)) and is_nil(Map.get(entry, :checkout_progress_sequence))
  end

  defp valid_sequence?(entry, %{kind: kind, sequence: sequence, previous_head: previous, head: head})
       when kind in [:observed, :durable] and is_integer(sequence) and sequence > 0 do
    old_sequence = Map.get(entry, :checkout_progress_sequence)

    is_integer(old_sequence) and old_sequence >= 0 and sequence == old_sequence + 1 and
      valid_head?(previous) and previous == Map.get(entry, :checkout_head) and previous != head
  end

  defp valid_sequence?(_entry, _checkpoint), do: false

  defp valid_kind?(:baseline, false), do: true
  defp valid_kind?(:observed, false), do: true
  defp valid_kind?(:durable, true), do: true
  defp valid_kind?(_kind, _changed), do: false

  defp valid_workspace?(entry, workspace, :baseline), do: Map.get(entry, :workspace_path) in [nil, workspace]
  defp valid_workspace?(entry, workspace, _kind), do: Map.get(entry, :workspace_path) == workspace

  defp valid_head?(head) when is_binary(head), do: Regex.match?(~r/\A[0-9a-f]{40}\z/, head)
  defp valid_head?(_head), do: false

  defp authorized(state, entry) do
    delegation_id = Map.get(entry, :responsibility_delegation_id)

    result =
      if is_nil(delegation_id) or not ResponsibilityGraph.enforced?(state.responsibility_graph) do
        ExecutionFence.authorize(state.execution_fence, entry.execution_token, :state_mutation)
      else
        ResponsibilityGraph.authorize_with_execution_fence(
          state.responsibility_graph,
          delegation_id,
          :state_mutation,
          state.execution_fence
        )
      end

    case result do
      {:ok, _metadata} -> :ok
      {:error, _} = error -> error
    end
  end

  defp transition(entry, checkpoint, now) do
    next =
      entry
      |> Map.put(:checkout_head, checkpoint.head)
      |> Map.put(:checkout_progress_sequence, checkpoint.sequence)

    if checkpoint.kind == :durable do
      next
      |> Map.put(:codex_durable_progress_token_baseline, entry.codex_total_tokens)
      |> Map.put(:codex_last_durable_progress_timestamp, now)
      |> Map.put(:codex_last_durable_progress_method, "managed_checkout_commit")
    else
      next
    end
  end
end
