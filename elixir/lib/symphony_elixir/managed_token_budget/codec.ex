defmodule SymphonyElixir.ManagedTokenBudget.Codec do
  @moduledoc "Strict replay of managed usage observations and explicit historical baselines."

  alias SymphonyElixir.ManagedTokenBudget.{Correction, Registration}

  @identity_keys ~w(pool_key repository_ref managed_project_profile_id)a
  @baseline_keys ~w(issue_id known_minimum_tokens continuation_floor evidence_ref authority_ref)a
  @usage_keys ~w(issue_id generation thread_id cumulative_total_tokens)a
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @spec initial_bytes(map(), [map()]) :: {:ok, binary()} | {:error, term()}
  def initial_bytes(identity, baselines) do
    with :ok <- validate_identity(identity),
         true <- is_list(baselines) and length(baselines) in 0..20,
         true <- Enum.all?(baselines, &valid_baseline?/1),
         ids = Enum.map(baselines, & &1.issue_id),
         true <- Enum.uniq(ids) == ids do
      records = [record("header", identity) | Enum.map(baselines, &record("bootstrap", &1))]
      {:ok, Enum.map_join(records, &encode/1)}
    else
      _ -> {:error, :invalid_budget_bootstrap}
    end
  end

  @spec validate_identity(term()) :: :ok | {:error, term()}
  def validate_identity(identity) do
    if exact_keys?(identity, @identity_keys) and Enum.all?(@identity_keys, &text?(identity[&1])),
      do: :ok,
      else: {:error, :invalid_managed_budget_identity}
  end

  @spec decode(binary(), map()) :: {:ok, map()} | {:error, term()}
  def decode(bytes, identity) when is_binary(bytes) do
    with :ok <- validate_identity(identity),
         true <- byte_size(bytes) > 0 and :binary.last(bytes) == ?\n,
         [header | lines] <- bytes |> String.split("\n") |> Enum.drop(-1),
         {:ok, expected} <- decode_record(header),
         true <- expected == record("header", identity),
         {:ok, state} <- replay(lines, bytes, byte_size(header) + 1),
         true <- map_size(state.baselines) in 0..20 do
      {:ok, state}
    else
      _ -> {:error, :invalid_budget_ledger}
    end
  end

  def decode(_bytes, _identity), do: {:error, :invalid_budget_ledger}

  @spec prepare(map(), String.t(), pos_integer(), String.t(), non_neg_integer()) ::
          {:ok, map(), map() | nil} | {:error, term()}
  def prepare(state, issue_id, generation, thread_id, cumulative) do
    attrs = %{issue_id: issue_id, generation: generation, thread_id: thread_id, cumulative_total_tokens: cumulative}

    with true <- valid_usage?(attrs),
         {:ok, baseline} <- Map.fetch(state.baselines, issue_id),
         true <- generation >= baseline.continuation_floor,
         true <- Map.get(state.threads, {issue_id, generation}, thread_id) == thread_id,
         false <- Enum.any?(state.threads, fn {key, value} -> value == thread_id and key != {issue_id, generation} end) do
      key = {issue_id, generation, thread_id}
      prior = Map.get(state.highwaters, key, 0)
      delta = max(cumulative - prior, 0)

      next = %{
        state
        | phase: :usage,
          threads: Map.put(state.threads, {issue_id, generation}, thread_id),
          highwaters: Map.put(state.highwaters, key, max(prior, cumulative)),
          issue_totals: Map.update!(state.issue_totals, issue_id, &(&1 + delta))
      }

      # The first zero observation still binds this generation to its real thread.
      row = if delta > 0 or not Map.has_key?(state.highwaters, key), do: record("usage", attrs)
      {:ok, next, row}
    else
      _ -> {:error, :invalid_usage_identity}
    end
  end

  @spec encode(map()) :: binary()
  def encode(row), do: Jason.encode!(row) <> "\n"

  defp replay(lines, bytes, offset) do
    state = %{
      baselines: %{},
      issue_totals: %{},
      highwaters: %{},
      threads: %{},
      corrections: %{},
      registrations: %{},
      phase: :bootstrap
    }

    Enum.reduce_while(lines, {:ok, state, offset}, fn line, {:ok, current, position} ->
      with {:ok, row} <- decode_record(line),
           {:ok, next} <- replay_record(current, row, bytes, position) do
        {:cont, {:ok, next, position + byte_size(line) + 1}}
      else
        _ -> {:halt, {:error, :invalid_budget_record}}
      end
    end)
    |> case do
      {:ok, state, _position} -> {:ok, state}
      error -> error
    end
  end

  defp replay_record(state, %{"kind" => "unstarted_floor_correction"} = row, bytes, position),
    do: Correction.replay(state, row, binary_part(bytes, 0, position))

  defp replay_record(state, %{"kind" => "new_issue_registration"} = row, bytes, position),
    do: Registration.replay(state, row, binary_part(bytes, 0, position))

  defp replay_record(state, row, _bytes, _position), do: apply_record(state, row)

  defp decode_record(line) do
    with {:ok, row} when is_map(row) <- Jason.decode(line),
         true <- Jason.encode!(row) == line do
      {:ok, row}
    else
      _ -> {:error, :noncanonical_budget_record}
    end
  end

  defp apply_record(%{phase: :bootstrap} = state, %{"kind" => "bootstrap", "version" => 1} = row) do
    attrs = attributes(row, @baseline_keys)

    if exact_record?(row, @baseline_keys) and valid_baseline?(attrs) and
         not Map.has_key?(state.baselines, attrs.issue_id) and map_size(state.baselines) < 20 do
      {:ok, %{state | baselines: Map.put(state.baselines, attrs.issue_id, attrs), issue_totals: Map.put(state.issue_totals, attrs.issue_id, attrs.known_minimum_tokens)}}
    else
      {:error, :invalid_budget_baseline}
    end
  end

  defp apply_record(state, %{"kind" => "usage", "version" => 1} = row) do
    attrs = attributes(row, @usage_keys)

    with true <- exact_record?(row, @usage_keys),
         {:ok, next, _row} <- prepare_record(state, attrs) do
      {:ok, next}
    else
      _ -> {:error, :invalid_usage_record}
    end
  end

  defp apply_record(_state, _row), do: {:error, :unexpected_budget_record}

  defp prepare_record(state, %{issue_id: id, generation: gen, thread_id: thread, cumulative_total_tokens: total}),
    do: prepare(state, id, gen, thread, total)

  defp valid_baseline?(attrs) do
    exact_keys?(attrs, @baseline_keys) and uuid?(attrs.issue_id) and nonnegative?(attrs.known_minimum_tokens) and
      positive?(attrs.continuation_floor) and text?(attrs.evidence_ref) and text?(attrs.authority_ref)
  end

  defp valid_usage?(%{issue_id: id, generation: gen, thread_id: thread, cumulative_total_tokens: total}) do
    uuid?(id) and positive?(gen) and text?(thread) and nonnegative?(total)
  end

  defp record(kind, attrs) do
    attrs |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end) |> Map.merge(%{"kind" => kind, "version" => 1})
  end

  defp attributes(row, keys), do: Map.new(keys, &{&1, row[Atom.to_string(&1)]})
  defp exact_record?(row, keys), do: exact_keys?(row, ["kind", "version" | Enum.map(keys, &Atom.to_string/1)])
  defp exact_keys?(map, keys) when is_map(map), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp exact_keys?(_map, _keys), do: false
  defp text?(value), do: is_binary(value) and byte_size(value) in 1..1024 and String.valid?(value) and String.trim(value) == value
  defp uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)
  defp nonnegative?(value), do: is_integer(value) and value >= 0
  defp positive?(value), do: is_integer(value) and value > 0
end
