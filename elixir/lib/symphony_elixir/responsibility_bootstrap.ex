defmodule SymphonyElixir.ResponsibilityBootstrap do
  @moduledoc """
  Trusted local bootstrap for machine-enforced responsibility admission.

  Activation is deliberately opt-in and requires a managed pool, the complete
  work-package runtime tuple, and an explicitly paused global mutable gate.
  The existing orchestrator transition owns validation and persistence.
  """

  alias SymphonyElixir.{GlobalPause, Orchestrator, WorkPackageRuntime}

  @spec activate(non_neg_integer()) :: :ok | {:error, term()}
  def activate(now_ms) when is_integer(now_ms) and now_ms >= 0 do
    with :ok <- managed_runtime_ready(),
         :ok <- global_pause_ready(),
         result <- Orchestrator.activate_responsibility_graph(now_ms) do
      normalize_activation_result(result)
    end
  end

  def activate(_now_ms), do: {:error, :invalid_activation_time}

  defp managed_runtime_ready do
    cond do
      not WorkPackageRuntime.managed_pool?() ->
        {:error, :managed_pool_required}

      true ->
        case WorkPackageRuntime.configuration() do
          {:ok, _runtime} -> :ok
          :disabled -> {:error, :managed_runtime_disabled}
          {:error, reason} -> {:error, {:invalid_managed_runtime, reason}}
        end
    end
  end

  defp global_pause_ready do
    case GlobalPause.snapshot() do
      %{configured?: true, paused?: true, state: "paused", reason: "operator_paused"} ->
        :ok

      %{configured?: false} ->
        {:error, :global_pause_unconfigured}

      %{configured?: true, paused?: false} ->
        {:error, :global_pause_not_paused}

      _status ->
        {:error, :global_pause_invalid}
    end
  end

  defp normalize_activation_result({:ok, :activated}), do: :ok
  defp normalize_activation_result({:ok, :already_activated}), do: :ok
  defp normalize_activation_result({:error, reason}), do: {:error, {:activation_failed, reason}}
  defp normalize_activation_result(:unavailable), do: {:error, :orchestrator_unavailable}
  defp normalize_activation_result(result), do: {:error, {:activation_failed, result}}
end
