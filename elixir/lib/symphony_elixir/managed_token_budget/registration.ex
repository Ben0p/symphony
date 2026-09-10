defmodule SymphonyElixir.ManagedTokenBudget.Registration do
  @moduledoc "Explicit append-only registration of a new canonical issue with no prior execution."

  @max_entries 20
  @attr_keys ~w(issue_id known_minimum_tokens continuation_floor evidence_ref authority_ref ledger_prefix_sha256 ledger_prefix_size_bytes)a
  @row_keys ["kind", "version" | Enum.map(@attr_keys, &Atom.to_string/1)]
  @state_maps ~w(baselines issue_totals highwaters threads corrections registrations)a
  @key_maps ~w(baselines issue_totals highwaters threads registrations)a
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @hash ~r/\A[0-9a-f]{64}\z/

  @spec prepare(map(), map(), binary()) :: {:ok, map(), map() | nil} | {:error, term()}
  def prepare(ledger, attrs, bytes) when is_map(ledger) and is_map(attrs) and is_binary(bytes) do
    with :ok <- valid_state(ledger),
         :ok <- validate_attrs(attrs),
         :ok <- valid_phase(Map.get(ledger, :phase)) do
      prepare_validated(ledger, attrs, bytes)
    end
  end

  def prepare(_, _, _), do: {:error, :registration_arguments_invalid}

  defp prepare_validated(ledger, attrs, bytes) do
    case Map.get(ledger.registrations, attrs.issue_id) do
      ^attrs ->
        # The bound prefix predates later usage. Exact logical retry after reload
        # returns the current ledger, while duplicate physical rows fail replay.
        {:ok, ledger, nil}

      nil ->
        with :ok <- pristine(ledger, attrs.issue_id),
             :ok <- under_limit(ledger),
             true <- prefix_matches?(attrs, bytes) do
          {:ok, apply_registration(ledger, attrs), row(attrs)}
        else
          false -> {:error, :registration_prefix_mismatch}
          error -> error
        end

      _ ->
        {:error, :registration_conflict}
    end
  end

  @spec replay(map(), map(), binary()) :: {:ok, map()} | {:error, term()}
  def replay(state, row, prefix) when is_map(state) and is_map(row) and is_binary(prefix) do
    with :ok <- valid_state(state),
         :ok <- validate_row(row),
         attrs = Map.new(@attr_keys, &{&1, row[Atom.to_string(&1)]}),
         :ok <- validate_attrs(attrs),
         :ok <- valid_phase(Map.get(state, :phase)),
         :ok <- pristine(state, attrs.issue_id),
         :ok <- under_limit(state),
         true <- prefix_matches?(attrs, prefix) do
      {:ok, apply_registration(state, attrs)}
    else
      false -> {:error, :registration_prefix_mismatch}
      error -> error
    end
  end

  def replay(_, _, _), do: {:error, :registration_arguments_invalid}

  defp valid_state(state) do
    if Enum.all?(@state_maps, &is_map(Map.get(state, &1))),
      do: :ok,
      else: {:error, :registration_state_invalid}
  end

  defp validate_attrs(attrs) do
    if exact_keys?(attrs, @attr_keys) and valid_uuid?(attrs.issue_id) and
         attrs.known_minimum_tokens === 0 and attrs.continuation_floor === 1 and
         valid_ref?(attrs.evidence_ref) and valid_ref?(attrs.authority_ref) and
         valid_prefix_attrs?(attrs),
       do: :ok,
       else: {:error, :registration_attrs_invalid}
  end

  defp valid_prefix_attrs?(attrs) do
    size = attrs.ledger_prefix_size_bytes
    valid_hash?(attrs.ledger_prefix_sha256) and is_integer(size) and size > 0
  end

  defp validate_row(row) do
    if exact_keys?(row, @row_keys) and row["kind"] == "new_issue_registration" and row["version"] === 1,
      do: :ok,
      else: {:error, :registration_record_invalid}
  end

  defp valid_uuid?(value), do: is_binary(value) and String.valid?(value) and Regex.match?(@uuid, value)
  defp valid_hash?(value), do: is_binary(value) and String.valid?(value) and Regex.match?(@hash, value)

  defp valid_ref?(value),
    do: is_binary(value) and String.valid?(value) and byte_size(value) in 1..1024 and String.trim(value) == value

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp valid_phase(phase) when phase in [:bootstrap, :usage], do: :ok
  defp valid_phase(_), do: {:error, :registration_phase_invalid}

  defp under_limit(%{baselines: baselines}) do
    if map_size(baselines) < @max_entries, do: :ok, else: {:error, :registration_limit}
  end

  defp pristine(state, issue_id) do
    key_present =
      Enum.any?(@key_maps, fn key ->
        Enum.any?(Map.keys(Map.fetch!(state, key)), &same_issue_key?(&1, issue_id))
      end)

    value_present =
      Enum.any?(@state_maps, fn key ->
        Enum.any?(Map.values(Map.fetch!(state, key)), &value_mentions_issue?(&1, issue_id))
      end)

    if key_present or value_present, do: {:error, :registration_issue_exists}, else: :ok
  end

  defp same_issue_key?({value, _}, issue_id), do: same_issue_key?(value, issue_id)
  defp same_issue_key?({value, _, _}, issue_id), do: same_issue_key?(value, issue_id)

  defp same_issue_key?(value, issue_id),
    do: is_binary(value) and String.valid?(value) and String.downcase(value) == issue_id

  defp value_mentions_issue?(value, issue_id) when is_map(value) do
    direct = Enum.any?([Map.get(value, :issue_id), Map.get(value, "issue_id")], &same_issue_key?(&1, issue_id))
    direct or Enum.any?(Map.values(value), &value_mentions_issue?(&1, issue_id))
  end

  defp value_mentions_issue?(_, _), do: false

  defp prefix_matches?(attrs, bytes) do
    attrs.ledger_prefix_size_bytes == byte_size(bytes) and
      attrs.ledger_prefix_sha256 == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end

  defp row(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.merge(%{"kind" => "new_issue_registration", "version" => 1})
  end

  defp apply_registration(state, attrs) do
    baseline = Map.take(attrs, ~w(issue_id known_minimum_tokens continuation_floor evidence_ref authority_ref)a)

    %{
      state
      | baselines: Map.put(state.baselines, attrs.issue_id, baseline),
        issue_totals: Map.put(state.issue_totals, attrs.issue_id, 0),
        registrations: Map.put(state.registrations, attrs.issue_id, attrs),
        phase: :usage
    }
  end
end
