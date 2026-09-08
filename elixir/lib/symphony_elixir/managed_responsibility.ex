defmodule SymphonyElixir.ManagedResponsibility do
  @moduledoc """
  Validates static operator authorization and proposes one exact responsibility pair.
  Intents remain inert until the normal orchestrator admits a fresh native issue.
  """

  alias SymphonyElixir.ResponsibilityGraph
  alias SymphonyElixir.ResponsibilityGraph.Persistence

  @routing [:pool_key, :repository_ref, :managed_project_profile_id]
  @payload_keys ~w(schema_version pool_key repository_ref managed_project_profile_id authority_ref entries)
  @entry_keys ~w(issue_id identifier owner_id accountable responsible)
  @scope_ids [:company_id, :objective_id, :initiative_id, :project_id, :work_package_id, :issue_id, :repository]
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  @identifier ~r/\A[A-Z][A-Z0-9_]*-[0-9]+\z/

  @spec decode(term(), term(), term()) :: {:ok, map()} | {:error, term()}
  def decode(payload, context, now_ms) when is_map(payload) and is_map(context) and is_integer(now_ms) and now_ms >= 0 do
    with true <- exact_keys?(payload, @payload_keys) and payload["schema_version"] == 1,
         true <- Enum.all?(@routing, &(present?(context[&1]) and payload[Atom.to_string(&1)] == context[&1])),
         true <- present?(payload["authority_ref"]),
         true <- present?(context[:runner_id]),
         entries when is_list(entries) and length(entries) in 0..20 <- payload["entries"],
         {:ok, decoded} <- decode_entries(entries, context, now_ms),
         true <- unique?(decoded) do
      manifest = Map.new(@routing, &{&1, context[&1]})
      {:ok, Map.merge(manifest, %{schema_version: 1, authority_ref: payload["authority_ref"], entries: decoded})}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_managed_delegation_manifest}
    end
  end

  def decode(_payload, _context, _now_ms), do: {:error, :invalid_managed_delegation_manifest}

  @spec admit(map(), map() | nil, map(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def admit(graph, nil, _issue, _now_ms), do: {:ok, graph}

  def admit(graph, %{schema_version: 1, entries: entries, repository_ref: repository}, issue, now_ms)
      when is_map(graph) and is_list(entries) and is_map(issue) and is_integer(now_ms) and now_ms >= 0 do
    with :ok <- ResponsibilityGraph.validate(graph),
         entry when is_map(entry) <- Enum.find(entries, &(&1.issue_id == issue.id and &1.identifier == issue.identifier)),
         true <- entry.owner_id == issue.assignee_id,
         true <- entry.accountable.expires_at_ms > now_ms and entry.responsible.expires_at_ms > now_ms,
         false <- repository_busy?(graph, entry.responsible.id, repository) do
      ensure_pair(graph, entry, now_ms)
    else
      {:error, _reason} = error -> error
      _ -> {:error, :managed_delegation_not_admissible}
    end
  end

  def admit(_graph, _manifest, _issue, _now_ms), do: {:error, :invalid_managed_delegation_input}

  defp decode_entries(entries, context, now_ms) do
    Enum.reduce_while(entries, {:ok, []}, fn raw, {:ok, acc} ->
      case decode_entry(raw, context, now_ms) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp decode_entry(raw, context, now_ms) when is_map(raw) do
    with true <- exact_keys?(raw, @entry_keys),
         true <- is_binary(raw["issue_id"]) and Regex.match?(@uuid, raw["issue_id"]),
         true <- is_binary(raw["identifier"]) and Regex.match?(@identifier, raw["identifier"]),
         true <- present?(raw["owner_id"]),
         {:ok, accountable} <- Persistence.decode_delegation_input(raw["accountable"]),
         {:ok, responsible} <- Persistence.decode_delegation_input(raw["responsible"]),
         true <- accountable.role == :accountable and is_nil(accountable.parent_delegation_id),
         true <- accountable.actor_id == raw["owner_id"],
         true <- responsible.role == :responsible and responsible.parent_delegation_id == accountable.id,
         true <- responsible.actor_id == context.runner_id,
         true <- responsible.budget.max_children == 0,
         true <- accountable.scope == responsible.scope,
         true <- bounded_scope?(responsible.scope, raw["issue_id"], context.repository_ref),
         true <- Enum.all?([accountable, responsible], &repository_authority?/1),
         {:ok, first, _} <- ResponsibilityGraph.delegate(ResponsibilityGraph.new(), accountable, now_ms),
         {:ok, _validated, _} <- ResponsibilityGraph.delegate(first, responsible, now_ms) do
      entry = %{
        issue_id: raw["issue_id"],
        identifier: raw["identifier"],
        owner_id: raw["owner_id"],
        accountable: accountable,
        responsible: responsible
      }

      {:ok, entry}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_managed_delegation_entry}
    end
  end

  defp decode_entry(_raw, _repository, _now_ms), do: {:error, :invalid_managed_delegation_entry}

  defp repository_authority?(delegation) do
    delegation.authority.class == :routine_engineering and delegation.authority.environments == ["repository"]
  end

  defp bounded_scope?(scope, issue_id, repository) do
    Enum.all?(@scope_ids, &(present?(scope[&1]) and not String.contains?(scope[&1], "*"))) and
      scope.issue_id == issue_id and scope.repository == repository and scope.environments == ["repository"] and
      scope.paths != [] and Enum.all?(scope.paths, &safe_path?/1)
  end

  defp ensure_pair(graph, entry, now_ms) do
    account = entry.accountable
    responsible = entry.responsible

    case {graph.delegations[account.id], graph.delegations[responsible.id]} do
      {nil, nil} ->
        with {:ok, first, _} <- ResponsibilityGraph.delegate(graph, account, now_ms),
             {:ok, second, _} <- ResponsibilityGraph.delegate(first, responsible, now_ms) do
          {:ok, second}
        end

      {%{status: :active} = existing_account, %{status: :active} = existing_responsible} ->
        if immutable_match?(existing_account, account) and immutable_match?(existing_responsible, responsible) do
          {:ok, graph}
        else
          {:error, :managed_delegation_changed}
        end

      _ ->
        {:error, :managed_delegation_pair_not_active}
    end
  end

  defp immutable_match?(existing, attrs), do: Map.take(existing, Map.keys(attrs)) == attrs

  defp repository_busy?(graph, selected_id, repository) do
    Enum.any?(graph.delegations, fn {id, delegation} ->
      id != selected_id and delegation.role == :responsible and
        delegation.status in [:active, :blocked] and delegation.scope.repository == repository
    end)
  end

  defp unique?(entries) do
    ids = Enum.flat_map(entries, &[&1.accountable.id, &1.responsible.id])
    issues = Enum.map(entries, & &1.issue_id)
    identifiers = Enum.map(entries, & &1.identifier)
    Enum.all?([ids, issues, identifiers], &(&1 == Enum.uniq(&1)))
  end

  defp safe_path?("."), do: true

  defp safe_path?(path) when is_binary(path) do
    present?(path) and not String.contains?(path, ["\\", ":"]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp safe_path?(_path), do: false

  defp exact_keys?(map, keys), do: MapSet.new(Map.keys(map)) == MapSet.new(keys)
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
