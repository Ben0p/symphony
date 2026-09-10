defmodule SymphonyElixir.ReviewHandoff do
  @moduledoc "Validates stopped managed generations and their current accepted merge."

  @spec entry(map(), map()) :: {:ok, map()} | {:error, atom()}
  def entry(execution, %{id: issue_id} = issue) when is_map(execution) do
    with true <- valid_execution?(execution, issue_id),
         workers = Enum.filter(Map.values(execution.leases), &(&1.role == :worker)),
         [worker] <- workers,
         identity when is_map(identity) and map_size(identity) > 0 <- worker[:supervisor_identity] do
      {:ok,
       %{
         execution_token: %{issue_id: issue_id, generation: execution.generation},
         execution_session_id: worker.session_id,
         process_id: worker.process_id,
         workspace_path: execution.worktree,
         worker_host: nil,
         issue: issue
       }}
    else
      _ -> {:error, :invalid_review_generation}
    end
  end

  def entry(_, _), do: {:error, :invalid_review_generation}

  @spec pending_executions(map(), [String.t()]) :: [{String.t(), map()}]
  def pending_executions(%{executions: executions}, running_ids)
      when is_map(executions) and is_list(running_ids) do
    executions
    |> Enum.filter(fn {id, execution} ->
      id not in running_ids and match?({:ok, _}, entry(execution, %{id: id}))
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  def pending_executions(_, _), do: []

  @spec accepted_merge(map(), map(), [map()]) :: {:ok, map()} | {:error, atom()}
  def accepted_merge(execution, snapshot, prs) when is_map(execution) and is_map(snapshot) and is_list(prs) do
    with {:ok, _} <- entry(execution, %{id: execution[:issue_id]}),
         true <- snapshot[:repository] == execution.repository and snapshot[:status] == "",
         true <- sha?(snapshot[:head]) and present?(snapshot[:branch]),
         true <- Enum.all?(prs, &is_map/1),
         false <- Enum.any?(prs, &(&1["state"] == "OPEN" and &1["headRefName"] == snapshot.branch)),
         [pr] <- Enum.filter(prs, &matching_merge?(&1, snapshot)),
         true <- valid_merge_identity?(pr, snapshot.repository) do
      {:ok, %{accepted_head: snapshot.head, merge_identity: pr["mergeCommit"]["oid"]}}
    else
      _ -> {:error, :accepted_merge_unavailable}
    end
  end

  def accepted_merge(_, _, _), do: {:error, :accepted_merge_unavailable}

  defp valid_execution?(execution, issue_id) do
    valid_scope?(execution, issue_id) and valid_generation?(execution) and
      execution[:cleanup] == :pending and valid_terminal?(execution) and
      is_map(execution[:leases]) and
      Enum.all?(execution.leases, fn {id, lease} -> valid_lease?(id, lease, execution) end)
  end

  defp valid_scope?(execution, issue_id) do
    present?(issue_id) and execution[:issue_id] == issue_id and
      repository?(execution[:repository]) and present?(execution[:worktree]) and
      present?(execution[:branch]) and Map.has_key?(execution, :worker_host) and
      is_nil(execution.worker_host)
  end

  defp valid_generation?(execution), do: is_integer(execution[:generation]) and execution.generation > 0

  defp valid_terminal?(%{status: :active, terminal: nil}), do: true

  defp valid_terminal?(%{status: :terminal, terminal: terminal}) when is_map(terminal) do
    not Map.has_key?(terminal, :failure_evidence_ref) and
      not Map.has_key?(terminal, "failure_evidence_ref") and
      present?(terminal[:state]) and sha?(terminal[:accepted_head]) and sha?(terminal[:merge_identity])
  end

  defp valid_terminal?(_), do: false

  defp valid_lease?(id, lease, execution) when is_map(lease) do
    present?(id) and lease[:session_id] == id and present?(lease[:process_id]) and
      lease[:role] in [:worker, :reviewer] and lease[:status] in [:released, :expired] and
      Enum.all?([:issue_id, :repository, :worktree, :branch, :generation], &(lease[&1] == execution[&1]))
  end

  defp valid_lease?(_, _, _), do: false

  defp matching_merge?(pr, snapshot) do
    pr["state"] == "MERGED" and pr["headRefName"] == snapshot.branch and
      pr["headRefOid"] == snapshot.head and pr["baseRefName"] == "main"
  end

  defp valid_merge_identity?(pr, repository) do
    number = pr["number"]

    is_integer(number) and number > 0 and pr["url"] == "https://github.com/#{repository}/pull/#{number}" and
      is_map(pr["mergeCommit"]) and sha?(pr["mergeCommit"]["oid"]) and timestamp?(pr["mergedAt"])
  end

  defp timestamp?(value) when is_binary(value), do: match?({:ok, _, _}, DateTime.from_iso8601(value))
  defp timestamp?(_), do: false
  defp repository?(value) when is_binary(value), do: String.valid?(value) and Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, value)
  defp repository?(_), do: false
  defp sha?(value) when is_binary(value), do: String.valid?(value) and Regex.match?(~r/\A[0-9a-f]{40}\z/, value)
  defp sha?(_), do: false
  defp present?(value), do: is_binary(value) and byte_size(value) > 0 and String.valid?(value)
end
