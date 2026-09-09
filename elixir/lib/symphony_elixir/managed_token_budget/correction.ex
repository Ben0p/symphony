defmodule SymphonyElixir.ManagedTokenBudget.Correction do
  @moduledoc "Explicit append-only correction of an unstarted issue's historical generation floor."

  @attr_keys ~w(issue_id correction_id previous_floor new_floor ledger_before_sha256 evidence_ref authority_ref)a
  @record_keys ["kind", "version" | Enum.map(@attr_keys, &Atom.to_string/1)]
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @spec prepare(map(), map(), binary()) :: {:ok, map(), map() | nil} | {:error, term()}
  def prepare(state, attrs, bytes) do
    with :ok <- validate_state(state),
         :ok <- validate_attrs(attrs) do
      prepare_validated(state, attrs, bytes)
    end
  end

  defp prepare_validated(state, attrs, bytes) do
    case Map.get(state.corrections, attrs.correction_id) do
      %{attrs: ^attrs} ->
        # The original prefix predates any later observations. An exact retry
        # remains idempotent after reload and after unrelated issue usage.
        {:ok, state, nil}

      nil ->
        with :ok <- prefix_matches?(attrs, bytes),
             {:ok, next} <- apply_new(state, attrs) do
          {:ok, next, record(attrs)}
        end

      _ ->
        {:error, :correction_id_conflict}
    end
  end

  @spec replay(map(), map(), binary()) :: {:ok, map()} | {:error, term()}
  def replay(state, row, prefix_bytes) do
    with :ok <- validate_state(state),
         true <- exact_keys?(row, @record_keys),
         %{"kind" => "unstarted_floor_correction", "version" => 1} <- row,
         attrs = Map.new(@attr_keys, &{&1, row[Atom.to_string(&1)]}),
         :ok <- validate_attrs(attrs),
         :ok <- prefix_matches?(attrs, prefix_bytes) do
      apply_new(state, attrs)
    else
      _ -> {:error, :invalid_unstarted_floor_correction}
    end
  end

  defp apply_new(state, attrs) do
    with false <- Map.has_key?(state.corrections, attrs.correction_id),
         false <- Enum.any?(state.corrections, fn {_id, entry} -> entry.attrs.issue_id == attrs.issue_id end),
         {:ok, baseline} <- Map.fetch(state.baselines, attrs.issue_id),
         :ok <- eligible?(state, baseline, attrs) do
      correction = %{original_baseline: baseline, attrs: attrs}

      {:ok,
       %{state | baselines: Map.put(state.baselines, attrs.issue_id, %{baseline | continuation_floor: 1}), corrections: Map.put(state.corrections, attrs.correction_id, correction), phase: :usage}}
    else
      _ -> {:error, :unstarted_floor_correction_not_eligible}
    end
  end

  defp eligible?(state, baseline, attrs) do
    issue = attrs.issue_id

    if baseline.known_minimum_tokens == 0 and baseline.continuation_floor == attrs.previous_floor and
         Map.get(state.issue_totals, issue) == 0 and
         not Enum.any?(state.highwaters, fn {{id, _generation, _thread}, _value} -> id == issue end) and
         not Enum.any?(state.threads, fn {{id, _generation}, _value} -> id == issue end) do
      :ok
    else
      {:error, :unstarted_floor_correction_not_eligible}
    end
  end

  defp validate_state(state) do
    required = [:baselines, :issue_totals, :highwaters, :threads, :corrections]

    if is_map(state) and Enum.all?(required, &is_map(Map.get(state, &1))) and Map.has_key?(state, :phase),
      do: :ok,
      else: {:error, :invalid_budget_state}
  end

  defp validate_attrs(attrs) do
    if exact_keys?(attrs, @attr_keys) and uuid?(attrs.issue_id) and text?(attrs.correction_id, 256) and
         valid_floor?(attrs) and digest?(attrs.ledger_before_sha256) and
         text?(attrs.evidence_ref, 1024) and text?(attrs.authority_ref, 1024) do
      :ok
    else
      {:error, :invalid_unstarted_floor_correction}
    end
  end

  defp uuid?(value), do: is_binary(value) and String.valid?(value) and Regex.match?(@uuid, value)

  defp valid_floor?(attrs),
    do: is_integer(attrs.previous_floor) and attrs.previous_floor > 1 and attrs.new_floor === 1

  defp digest?(value),
    do: is_binary(value) and byte_size(value) == 64 and String.valid?(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp prefix_matches?(attrs, bytes) when is_binary(bytes) do
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    if attrs.ledger_before_sha256 == actual, do: :ok, else: {:error, :correction_prefix_mismatch}
  end

  defp prefix_matches?(_attrs, _bytes), do: {:error, :correction_prefix_mismatch}

  defp record(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.merge(%{"kind" => "unstarted_floor_correction", "version" => 1})
  end

  defp text?(value, limit),
    do: is_binary(value) and byte_size(value) in 1..limit and String.valid?(value) and String.trim(value) == value

  defp exact_keys?(map, keys) when is_map(map), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp exact_keys?(_map, _keys), do: false
end
