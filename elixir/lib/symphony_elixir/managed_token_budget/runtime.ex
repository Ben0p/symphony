defmodule SymphonyElixir.ManagedTokenBudget.Runtime do
  @moduledoc "Managed scheduler accounting, with an explicit historical bootstrap and a latched failure boundary."

  alias SymphonyElixir.{Config, ManagedTokenBudget}

  @spec load(map()) :: {:ok, map()} | {:error, term()}
  def load(%{work_package_runtime: nil} = state), do: {:ok, state}

  def load(%{work_package_runtime: runtime} = state) do
    with {:ok, path, identity} <- location(runtime),
         {:ok, ledger} <- ManagedTokenBudget.load(path, identity) do
      {:ok, %{state | managed_token_budget: ledger, codex_issue_totals: ledger.issue_totals}}
    end
  end

  @spec location(map()) :: {:ok, Path.t(), map()} | {:error, term()}
  def location(%{journal_path: path, managed_project_profile_id: profile, managed_delegations: manifest})
      when is_binary(path) and is_map(manifest) do
    identity = Map.take(manifest, [:pool_key, :repository_ref, :managed_project_profile_id])

    if identity[:managed_project_profile_id] == profile,
      do: {:ok, path <> ".token-usage.jsonl", identity},
      else: {:error, :managed_budget_profile_mismatch}
  end

  def location(_runtime), do: {:error, :managed_budget_configuration_required}

  @spec admission(map(), String.t()) :: :ok | {:error, term()}
  def admission(%{work_package_runtime: nil}, _issue_id), do: :ok

  def admission(%{managed_token_budget_error: nil, managed_token_budget: ledger} = state, issue_id)
      when is_map(ledger) do
    threshold = Config.settings!().codex.max_total_tokens
    entries = get_in(state.work_package_runtime, [:managed_delegations, :entries]) || []
    entry = Enum.find(entries, &(&1.issue_id == issue_id))
    grant_limit = get_in(entry || %{}, [:responsible, :budget, :max_tokens])

    with {:ok, path, identity} <- location(state.work_package_runtime),
         true <- path == ledger.path and identity == ledger.identity,
         :ok <- ManagedTokenBudget.verify(ledger),
         {:ok, total} <- Map.fetch(ledger.issue_totals, issue_id),
         true <- is_integer(threshold) and threshold > 0 and is_integer(grant_limit) and threshold <= grant_limit,
         true <- total < threshold do
      :ok
    else
      _ -> {:error, :managed_token_budget_unavailable_or_exhausted}
    end
  end

  def admission(_state, _issue_id), do: {:error, :managed_token_budget_unavailable_or_exhausted}

  @spec generation(map(), map()) :: :ok | {:error, term()}
  def generation(%{work_package_runtime: nil}, _token), do: :ok

  def generation(%{managed_token_budget: %{baselines: baselines}}, %{issue_id: issue_id, generation: generation}) do
    case Map.get(baselines, issue_id) do
      %{continuation_floor: floor} when generation >= floor -> :ok
      _ -> {:error, :managed_budget_generation_before_floor}
    end
  end

  def generation(_state, _token), do: {:error, :managed_token_budget_unavailable}

  @spec observe(map(), String.t(), map()) :: map()
  def observe(state, issue_id, entry), do: observe(state, issue_id, entry, %{})

  @spec observe(map(), String.t(), map(), map()) :: map()
  def observe(%{work_package_runtime: nil} = state, _issue_id, _entry, _update), do: state
  def observe(%{managed_token_budget_error: error} = state, _issue_id, _entry, _update) when not is_nil(error), do: state

  def observe(state, issue_id, entry, update) do
    result = with :ok <- matching_thread(entry, update), do: observation(state.managed_token_budget, issue_id, entry)

    case result do
      {:ok, ledger} -> %{state | managed_token_budget: ledger, codex_issue_totals: ledger.issue_totals}
      {:error, reason} -> latch(state, reason)
    end
  end

  @spec latch(map(), term()) :: map()
  def latch(%{managed_token_budget_error: error} = state, _reason) when not is_nil(error), do: state

  def latch(state, reason) do
    # A storage failure may also prevent this marker. The live scheduler still
    # latches; existing execution claims require explicit recovery after restart.
    retained = ManagedTokenBudget.block(state.managed_token_budget)
    %{state | managed_token_budget_error: {reason, retained}}
  end

  @spec release_totals(map(), String.t()) :: map()
  def release_totals(%{work_package_runtime: nil} = state, issue_id),
    do: Map.delete(state.codex_issue_totals || %{}, issue_id)

  def release_totals(state, _issue_id), do: state.codex_issue_totals

  defp matching_thread(entry, update) do
    observed = payload_thread(update[:payload]) || update[:thread_id]
    expected = get_in(entry, [:codex_session_identity, :thread_id])
    if is_nil(observed) or observed == expected, do: :ok, else: {:error, :managed_usage_thread_mismatch}
  end

  defp payload_thread(%{"params" => %{} = params}), do: params["threadId"] || params[:threadId]
  defp payload_thread(%{params: %{} = params}), do: params["threadId"] || params[:threadId]
  defp payload_thread(_payload), do: nil

  defp observation(ledger, issue_id, %{execution_token: %{issue_id: issue_id, generation: generation}} = entry)
       when is_map(ledger) do
    total = Map.get(entry, :codex_last_reported_total_tokens, 0)
    thread = get_in(entry, [:codex_session_identity, :thread_id])

    case {thread, total} do
      {nil, 0} -> with :ok <- ManagedTokenBudget.verify(ledger), do: {:ok, ledger}
      {thread, total} -> ManagedTokenBudget.observe(ledger, issue_id, generation, thread, total)
    end
  end

  defp observation(_ledger, _issue_id, _entry), do: {:error, :managed_usage_identity_required}
end
