defmodule SymphonyElixir.StartupMaintenance do
  @moduledoc """
  Bounded startup maintenance that keeps slow tracker cleanup away from the
  orchestrator init path.
  """

  alias SymphonyElixir.Tracker.Issue

  @timeout_ms 60_000
  @max_error_summary_bytes 240
  @secret_patterns [
    ~r/lin_api_[A-Za-z0-9_\-]+/,
    ~r/github_pat_[A-Za-z0-9_\-]+/,
    ~r/gh[pousr]_[A-Za-z0-9_\-]+/,
    ~r/sk-[A-Za-z0-9_\-]+/
  ]

  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: @timeout_ms

  @spec start() :: map()
  def start do
    %{
      status: "running",
      started_at: DateTime.utc_now(),
      started_monotonic_ms: System.monotonic_time(:millisecond),
      timeout_ms: @timeout_ms,
      cleaned_count: 0,
      skipped_active_count: 0,
      failure_count: 0
    }
  end

  @spec run((list(String.t()) -> {:ok, list(Issue.t())} | {:error, term()}), (Issue.t() -> term()), map()) ::
          {:ok, map()}
  def run(fetch_by_states, cleanup_issue, tracker_settings)
      when is_function(fetch_by_states, 1) and is_function(cleanup_issue, 1) and is_map(tracker_settings) do
    started_ms = System.monotonic_time(:millisecond)
    active_states = Map.get(tracker_settings, :active_states, [])
    terminal_states = Map.get(tracker_settings, :terminal_states, [])

    with {:ok, active_issues} <- fetch_by_states.(active_states),
         {:ok, terminal_issues} <- fetch_by_states.(terminal_states) do
      active_keys = issue_keys(active_issues)

      {cleaned_count, skipped_active_count, failures} =
        terminal_issues
        |> Enum.filter(&match?(%Issue{}, &1))
        |> Enum.reduce({0, 0, []}, fn issue, {cleaned, skipped, failures_acc} ->
          if active_issue?(issue, active_keys) do
            {cleaned, skipped + 1, failures_acc}
          else
            case safe_cleanup(cleanup_issue, issue) do
              :ok ->
                {cleaned + 1, skipped, failures_acc}

              {:error, reason} ->
                {cleaned, skipped, [cleanup_failure(issue, reason) | failures_acc]}
            end
          end
        end)

      failures = Enum.reverse(failures)

      {:ok,
       %{
         status: if(failures == [], do: "succeeded", else: "failed"),
         duration_ms: elapsed_ms(started_ms),
         active_issue_count: length(active_issues),
         terminal_issue_count: length(terminal_issues),
         cleaned_count: cleaned_count,
         skipped_active_count: skipped_active_count,
         failure_count: length(failures),
         failures: Enum.take(failures, 5)
       }}
    else
      {:error, reason} ->
        {:ok,
         %{
           status: "failed",
           duration_ms: elapsed_ms(started_ms),
           cleaned_count: 0,
           skipped_active_count: 0,
           failure_count: 1,
           error_summary: "tracker fetch failed: " <> sanitize_reason(reason)
         }}
    end
  end

  @spec complete(map() | nil, map()) :: map()
  def complete(maintenance, result) when is_map(maintenance) and is_map(result) do
    finished_at = DateTime.utc_now()
    status = Map.get(result, :status, "succeeded")

    maintenance
    |> Map.drop([:task_ref, :task_pid])
    |> Map.merge(result)
    |> Map.put(:status, status)
    |> Map.put(:finished_at, finished_at)
    |> Map.put_new(:duration_ms, duration_ms(maintenance))
    |> maybe_record_last_success(status, finished_at)
  end

  def complete(_maintenance, result) when is_map(result), do: result

  @spec timeout(map() | nil) :: map()
  def timeout(maintenance) when is_map(maintenance) do
    maintenance
    |> Map.drop([:task_ref, :task_pid])
    |> Map.put(:status, "timed_out")
    |> Map.put(:finished_at, DateTime.utc_now())
    |> Map.put(:duration_ms, duration_ms(maintenance))
    |> Map.put(:failure_count, max(1, Map.get(maintenance, :failure_count, 0)))
    |> Map.put(:error_summary, "startup maintenance exceeded #{timeout_ms()}ms")
  end

  def timeout(_maintenance) do
    %{
      status: "timed_out",
      finished_at: DateTime.utc_now(),
      timeout_ms: timeout_ms(),
      failure_count: 1,
      error_summary: "startup maintenance exceeded #{timeout_ms()}ms"
    }
  end

  @spec fail(map() | nil, term()) :: map()
  def fail(maintenance, reason) when is_map(maintenance) do
    maintenance
    |> Map.drop([:task_ref, :task_pid])
    |> Map.put(:status, "failed")
    |> Map.put(:finished_at, DateTime.utc_now())
    |> Map.put(:duration_ms, duration_ms(maintenance))
    |> Map.put(:failure_count, max(1, Map.get(maintenance, :failure_count, 0)))
    |> Map.put(:error_summary, sanitize_reason(reason))
  end

  def fail(_maintenance, reason) do
    %{
      status: "failed",
      finished_at: DateTime.utc_now(),
      failure_count: 1,
      error_summary: sanitize_reason(reason)
    }
  end

  @spec snapshot(map() | nil) :: map() | nil
  def snapshot(nil), do: nil

  def snapshot(maintenance) when is_map(maintenance) do
    Map.drop(maintenance, [:task_ref, :task_pid, :started_monotonic_ms])
  end

  defp safe_cleanup(cleanup_issue, %Issue{} = issue) do
    case cleanup_issue.(issue) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_cleanup_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp issue_keys(issues) when is_list(issues) do
    issues
    |> Enum.flat_map(fn
      %Issue{id: id, identifier: identifier} -> [id, identifier]
      _ -> []
    end)
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp active_issue?(%Issue{id: id, identifier: identifier}, active_keys) do
    MapSet.member?(active_keys, id) or MapSet.member?(active_keys, identifier)
  end

  defp cleanup_failure(%Issue{id: id, identifier: identifier}, reason) do
    %{
      issue_id: id,
      issue_identifier: identifier,
      error_summary: sanitize_reason(reason)
    }
  end

  defp maybe_record_last_success(maintenance, "succeeded", finished_at) do
    Map.put(maintenance, :last_success_at, finished_at)
  end

  defp maybe_record_last_success(maintenance, _status, _finished_at), do: maintenance

  defp duration_ms(%{started_monotonic_ms: started_ms}) when is_integer(started_ms) do
    elapsed_ms(started_ms)
  end

  defp duration_ms(_maintenance), do: nil

  defp elapsed_ms(started_ms) when is_integer(started_ms) do
    max(0, System.monotonic_time(:millisecond) - started_ms)
  end

  defp sanitize_reason(reason) do
    reason
    |> reason_class()
    |> redact_secret_patterns()
    |> truncate(@max_error_summary_bytes)
  end

  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_class({kind, _detail}) when is_atom(kind) do
    "#{kind}: [redacted]"
  end

  defp reason_class(%{__struct__: module}) when is_atom(module) do
    "#{inspect(module)}: [redacted]"
  end

  defp reason_class(_reason), do: "unavailable: [redacted]"

  defp redact_secret_patterns(value) when is_binary(value) do
    Enum.reduce(@secret_patterns, value, fn pattern, redacted ->
      Regex.replace(pattern, redacted, "[redacted]")
    end)
  end

  defp truncate(value, max_bytes) when byte_size(value) <= max_bytes, do: value
  defp truncate(value, max_bytes), do: binary_part(value, 0, max_bytes) <> "..."
end
