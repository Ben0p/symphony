defmodule SymphonyElixir.ManagedTokenBudget.Limit do
  @moduledoc "Intersects the configured per-issue ceiling with one explicit managed grant."

  @error {:error, :managed_token_budget_unavailable_or_exhausted}
  @type error :: {:error, :managed_token_budget_unavailable_or_exhausted}
  @type result :: {:ok, non_neg_integer(), map() | nil} | error()

  @spec bounded(term(), term()) :: {:ok, pos_integer()} | error()
  def bounded(configured, %{budget: %{max_tokens: maximum}})
      when is_integer(configured) and configured > 0 and is_integer(maximum) and maximum > 0,
      do: {:ok, min(configured, maximum)}

  def bounded(_, _), do: @error

  @spec resolve(term(), term(), term()) :: result()
  def resolve(configured, nil, _issue_id) when is_integer(configured) and configured >= 0,
    do: {:ok, configured, nil}

  def resolve(configured, %{managed_delegations: %{entries: entries}}, issue_id)
      when is_integer(configured) and configured > 0 and is_list(entries) do
    with true <- is_binary(issue_id) and byte_size(issue_id) > 0,
         {:ok, matches} <- validate_entries(entries, issue_id),
         {:ok, responsible} <- exactly_one(matches),
         {:ok, limit} <- bounded(configured, responsible) do
      {:ok, limit, responsible}
    else
      _ -> @error
    end
  end

  def resolve(_, _, _), do: @error

  defp validate_entries(entries, requested) do
    Enum.reduce_while(entries, {:ok, MapSet.new(), MapSet.new(), []}, &collect_entry(&1, &2, requested))
    |> case do
      {:ok, _seen, _grants, matches} -> {:ok, matches}
      error -> error
    end
  end

  defp collect_entry(entry, {:ok, seen, grants, matches}, requested) do
    with {:ok, id, grant} <- valid_entry(entry),
         false <- MapSet.member?(seen, id) or MapSet.member?(grants, grant.id) do
      found = if id == requested, do: [grant | matches], else: matches
      {:cont, {:ok, MapSet.put(seen, id), MapSet.put(grants, grant.id), found}}
    else
      _ -> {:halt, @error}
    end
  end

  defp valid_entry(%{issue_id: issue_id, responsible: %{id: id, budget: %{max_tokens: maximum}} = grant})
       when is_binary(issue_id) and byte_size(issue_id) > 0 and is_binary(id) and byte_size(id) > 0 and
              is_integer(maximum) and maximum > 0,
       do: {:ok, issue_id, grant}

  defp valid_entry(_), do: :error
  defp exactly_one([grant]), do: {:ok, grant}
  defp exactly_one(_), do: @error
end
