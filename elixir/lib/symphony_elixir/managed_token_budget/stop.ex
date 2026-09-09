defmodule SymphonyElixir.ManagedTokenBudget.Stop do
  @moduledoc "Drains already queued, exactly bound usage after a managed worker has stopped."

  alias SymphonyElixir.ManagedTokenBudget.Runtime

  @spec drain(map(), String.t(), map(), (map(), map(), map() -> {map(), map()})) :: {map(), map()}
  def drain(%{work_package_runtime: nil} = state, _issue_id, entry, _integrate), do: {state, entry}

  def drain(state, issue_id, %{pid: pid, execution_token: %{issue_id: issue_id} = token, execution_session_id: session} = entry, integrate) do
    if is_pid(pid) and not Process.alive?(pid),
      do: drain_bound(state, entry, integrate, {issue_id, token, session}, 10_000),
      else: {Runtime.latch(state, :managed_worker_stop_unconfirmed), entry}
  end

  def drain(state, _issue_id, entry, _integrate),
    do: {Runtime.latch(state, :managed_worker_stop_unconfirmed), entry}

  defp drain_bound(%{managed_token_budget_error: error} = state, entry, _integrate, _identity, _remaining)
       when not is_nil(error), do: {state, entry}

  defp drain_bound(state, entry, _integrate, _identity, 0),
    do: {Runtime.latch(state, :managed_usage_drain_limit), entry}

  defp drain_bound(state, entry, integrate, {id, key, sid} = identity, remaining) do
    receive do
      {:codex_worker_update, ^id, %{execution_token: ^key, execution_session_id: ^sid, event: _, timestamp: _} = msg} ->
        {state, entry} = integrate.(state, entry, msg)
        drain_bound(state, entry, integrate, identity, remaining - 1)
    after
      0 -> {state, entry}
    end
  end
end
