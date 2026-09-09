defmodule SymphonyElixir.Codex.SupervisedStartup do
  @moduledoc """
  Waits for a newly launched scope in the process that owns its Codex port.

  Port data stays in the mailbox so protocol startup sees its original order.
  No protocol request is sent while the live containment identity is pending.
  """

  alias SymphonyElixir.ExecutionSupervisor

  @deadline_ms 5_000
  @poll_ms 50
  @max_output_bytes 1_048_576
  @max_output_events 64

  @spec capture(port(), ExecutionSupervisor.identity() | nil, (-> term()), keyword()) ::
          {:ok, ExecutionSupervisor.identity() | nil} | {:error, term(), ExecutionSupervisor.identity() | nil}
  def capture(port, identity, guard, opts \\ []) do
    case identity do
      nil ->
        {:ok, nil}

      _ ->
        deadline = now_ms() + Keyword.get(opts, :timeout_ms, @deadline_ms)
        capture = Keyword.get(opts, :capture, &ExecutionSupervisor.capture/2)
        await_capture(port, identity, guard, capture, deadline)
    end
  end

  defp await_capture(port, identity, guard, capture, deadline) do
    with :ok <- port_status(port, deadline),
         :ok <- check_guard(guard),
         remaining when remaining > 0 <- deadline - now_ms(),
         result <- capture.(identity, timeout_ms: min(remaining, 1_000)) do
      handle_capture(result, port, identity, guard, capture, deadline)
    else
      remaining when is_integer(remaining) -> failure(port, :supervisor_startup_timeout)
      {:error, reason} -> failure(port, reason)
    end
  end

  defp handle_capture({:ok, captured}, port, _identity, guard, _capture, deadline) do
    with :ok <- port_status(port, deadline),
         :ok <- check_guard(guard),
         true <- now_ms() < deadline do
      {:ok, captured}
    else
      false -> failure(port, :supervisor_startup_timeout, captured)
      {:error, reason} -> failure(port, reason, captured)
    end
  end

  defp handle_capture({:error, reason}, port, identity, guard, capture, deadline)
       when reason in [{:systemd_unit_not_loaded, "not-found"}, {:systemd_unit_not_active, "inactive"}] do
    receive do
      {^port, {:exit_status, status}} -> failure(port, {:supervisor_port_exited, status})
    after
      min(@poll_ms, max(0, deadline - now_ms())) -> await_capture(port, identity, guard, capture, deadline)
    end
  end

  defp handle_capture({:error, reason}, port, _identity, _guard, _capture, _deadline), do: failure(port, reason)

  defp check_guard(guard) do
    case guard.() do
      :ok -> :ok
      {:ok, _metadata} -> :ok
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_execution_fence_guard_result}
    end
  rescue
    _ -> {:error, :execution_fence_guard_failed}
  catch
    _, _ -> {:error, :execution_fence_guard_failed}
  end

  defp port_status(port, deadline) do
    receive do
      {^port, {:exit_status, status}} -> {:error, {:supervisor_port_exited, status}}
    after
      0 ->
        summary = output_summary(port)

        cond do
          summary.bytes > @max_output_bytes or summary.events > @max_output_events -> {:error, :supervisor_startup_output_overflow}
          is_nil(Port.info(port)) -> closed_port_status(port, max(0, min(@poll_ms, deadline - now_ms())))
          true -> :ok
        end
    end
  end

  defp closed_port_status(port, wait_ms) do
    receive do
      {^port, {:exit_status, status}} -> {:error, {:supervisor_port_exited, status}}
    after
      wait_ms -> {:error, :supervisor_port_closed}
    end
  end

  defp failure(port, reason, captured \\ nil), do: {:error, {:supervisor_startup_failed, reason, output_summary(port)}, captured}

  defp output_summary(port) do
    {:messages, messages} = Process.info(self(), :messages)

    Enum.reduce(messages, %{bytes: 0, events: 0, chunk_sha256: []}, fn
      {^port, {:data, {kind, data}}}, summary when kind in [:eol, :noeol] and is_binary(data) ->
        hashes =
          if summary.events < @max_output_events,
            do: summary.chunk_sha256 ++ [Base.encode16(:crypto.hash(:sha256, data), case: :lower)],
            else: summary.chunk_sha256

        %{bytes: summary.bytes + byte_size(data), events: summary.events + 1, chunk_sha256: hashes}

      _, summary ->
        summary
    end)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
