defmodule SymphonyElixir.Linear.RateLimiter do
  @moduledoc """
  Coordinates Linear requests across Symphony processes on one host.

  Each pool is a separate OS process, so an in-memory limiter cannot protect
  the shared Linear API key. A short-lived exclusive lock and a wall-clock
  reservation timestamp in a shared file provide a small host-local gate.
  """

  require Logger

  @default_min_interval_ms 250
  @default_max_wait_ms 30_000
  @default_stale_lock_ms 5_000
  @default_max_retry_after_ms 3_600_000
  @lock_poll_ms 10

  @type settings :: %{
          state_path: Path.t(),
          lock_path: Path.t(),
          min_interval_ms: non_neg_integer(),
          max_wait_ms: pos_integer(),
          stale_lock_ms: pos_integer(),
          max_retry_after_ms: non_neg_integer()
        }

  @spec await(map()) :: :ok | {:error, term()}
  def await(tracker_settings) when is_map(tracker_settings) do
    settings = settings(tracker_settings)

    with :ok <- ensure_parent(settings.state_path),
         :ok <- ensure_parent(settings.lock_path),
         {:ok, wait_ms} <- reserve(settings) do
      if wait_ms > 0, do: Process.sleep(wait_ms)
      :ok
    end
  end

  @spec observe_response(map(), term()) :: :ok
  def observe_response(tracker_settings, response) when is_map(tracker_settings) and is_map(response) do
    settings = settings(tracker_settings)

    case retry_after_ms(response, settings.max_retry_after_ms) do
      retry_after when is_integer(retry_after) and retry_after > 0 ->
        case with_lock(settings, fn -> extend_cooldown(settings, retry_after) end) do
          {:ok, _result} -> :ok
          {:error, reason} -> Logger.warning("Unable to persist Linear rate-limit cooldown: #{inspect(reason)}")
        end

      _ ->
        :ok
    end

    :ok
  end

  def observe_response(_tracker_settings, _response), do: :ok

  defp settings(tracker_settings) do
    provider = Map.get(tracker_settings, :provider) || Map.get(tracker_settings, "provider") || %{}

    state_path =
      provider_value(provider, "rate_limit_file") ||
        System.get_env("SYMPHONY_LINEAR_RATE_LIMIT_FILE") ||
        Path.join(System.tmp_dir!(), "symphony-linear-rate-limit.state")

    %{
      state_path: state_path,
      lock_path: state_path <> ".lock",
      min_interval_ms: nonnegative_integer(provider_value(provider, "rate_limit_min_interval_ms"), "SYMPHONY_LINEAR_RATE_LIMIT_MIN_INTERVAL_MS", @default_min_interval_ms),
      max_wait_ms: positive_integer(provider_value(provider, "rate_limit_max_wait_ms"), "SYMPHONY_LINEAR_RATE_LIMIT_MAX_WAIT_MS", @default_max_wait_ms),
      stale_lock_ms: positive_integer(provider_value(provider, "rate_limit_stale_lock_ms"), "SYMPHONY_LINEAR_RATE_LIMIT_STALE_LOCK_MS", @default_stale_lock_ms),
      max_retry_after_ms: nonnegative_integer(provider_value(provider, "rate_limit_max_retry_after_ms"), "SYMPHONY_LINEAR_RATE_LIMIT_MAX_RETRY_AFTER_MS", @default_max_retry_after_ms)
    }
  end

  defp provider_value(provider, key) when is_map(provider) do
    case Map.get(provider, key) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      value when is_integer(value) and value >= 0 -> value
      _ -> nil
    end
  end

  defp provider_value(_provider, _key), do: nil

  defp nonnegative_integer(value, env_name, default) do
    parse_integer(value || System.get_env(env_name), default, &(&1 >= 0))
  end

  defp positive_integer(value, env_name, default) do
    parse_integer(value || System.get_env(env_name), default, &(&1 > 0))
  end

  defp parse_integer(value, default, predicate) when is_integer(value) do
    if predicate.(value), do: value, else: default
  end

  defp parse_integer(value, default, predicate) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> if predicate.(parsed), do: parsed, else: default
      _ -> default
    end
  end

  defp parse_integer(_value, default, _predicate), do: default

  defp ensure_parent(path) do
    case Path.dirname(path) do
      "." -> :ok
      parent -> File.mkdir_p(parent)
    end
  end

  defp reserve(settings) do
    with_lock(settings, fn ->
      now = System.system_time(:millisecond)
      next_allowed_at = read_next_allowed_at(settings.state_path)
      wait_ms = if is_integer(next_allowed_at), do: max(next_allowed_at - now, 0), else: 0

      if wait_ms > settings.max_wait_ms do
        {:error, :linear_rate_limit_wait_exceeded}
      else
        reserved_until = max(next_allowed_at || now, now) + settings.min_interval_ms

        case File.write(settings.state_path, Integer.to_string(reserved_until), [:write, :binary]) do
          :ok -> {:ok, wait_ms}
          {:error, reason} -> {:error, {:linear_rate_limit_state_write_failed, reason}}
        end
      end
    end)
  end

  defp extend_cooldown(settings, retry_after_ms) do
    now = System.system_time(:millisecond)
    next_allowed_at = max(read_next_allowed_at(settings.state_path) || now, now + retry_after_ms)

    case File.write(settings.state_path, Integer.to_string(next_allowed_at), [:write, :binary]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:linear_rate_limit_state_write_failed, reason}}
    end
  end

  defp read_next_allowed_at(path) do
    case File.read(path) do
      {:ok, value} ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} when is_integer(parsed) -> parsed
          _ -> 0
        end

      {:error, :enoent} ->
        nil

      {:error, reason} ->
        Logger.warning("Unable to read Linear rate-limit state: #{inspect(reason)}")
        nil
    end
  end

  defp with_lock(settings, fun) when is_function(fun, 0) do
    started_at = System.monotonic_time(:millisecond)
    acquire_lock(settings, fun, started_at)
  end

  defp acquire_lock(settings, fun, started_at) do
    case File.open(settings.lock_path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        result =
          try do
            fun.()
          after
            File.close(io)
            File.rm(settings.lock_path)
          end

        case result do
          {:error, reason} -> {:error, reason}
          {:ok, value} -> {:ok, value}
          value -> {:ok, value}
        end

      {:error, :eexist} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        cond do
          elapsed_ms >= settings.max_wait_ms ->
            {:error, :linear_rate_limit_lock_timeout}

          stale_lock?(settings.lock_path, settings.stale_lock_ms) ->
            File.rm(settings.lock_path)
            acquire_lock(settings, fun, started_at)

          true ->
            Process.sleep(@lock_poll_ms)
            acquire_lock(settings, fun, started_at)
        end

      {:error, reason} ->
        {:error, {:linear_rate_limit_lock_open_failed, reason}}
    end
  end

  defp stale_lock?(path, stale_lock_ms) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: modified_at}} when is_integer(modified_at) ->
        System.system_time(:millisecond) - modified_at * 1_000 >= stale_lock_ms

      _ ->
        false
    end
  end

  defp retry_after_ms(response, max_retry_after_ms) do
    header_ms =
      response
      |> response_headers()
      |> Enum.find_value(&retry_after_header/1)
      |> parse_retry_after(max_retry_after_ms)

    embedded_ms = graphql_rate_limit_duration_ms(response)

    min(max(header_ms, embedded_ms), max_retry_after_ms)
  end

  defp graphql_rate_limit_duration_ms(%{body: %{"errors" => errors}}) when is_list(errors) do
    Enum.find_value(errors, 0, fn error ->
      if graphql_rate_limited_error?(error) do
        case get_in(error, ["extensions", "meta", "rateLimitResult", "duration"]) do
          duration when is_integer(duration) and duration > 0 -> duration
          _ -> false
        end
      else
        false
      end
    end)
  end

  defp graphql_rate_limit_duration_ms(_response), do: 0

  defp graphql_rate_limited_error?(error) when is_map(error) do
    Map.get(error, "type") == "ratelimited" or
      get_in(error, ["extensions", "statusCode"]) == 429
  end

  defp graphql_rate_limited_error?(_error), do: false

  defp response_headers(response) do
    Map.get(response, :headers) || Map.get(response, "headers") || []
  end

  defp retry_after_header({name, value}) do
    if String.downcase(to_string(name)) == "retry-after", do: value
  end

  defp retry_after_header(%{"name" => name, "value" => value}) do
    if String.downcase(to_string(name)) == "retry-after", do: value
  end

  defp retry_after_header(%{name: name, value: value}) do
    if String.downcase(to_string(name)) == "retry-after", do: value
  end

  defp retry_after_header(_header), do: nil

  defp parse_retry_after(value, max_retry_after_ms) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 -> min(seconds * 1_000, max_retry_after_ms)
      _ -> 0
    end
  end

  defp parse_retry_after(_value, _max_retry_after_ms), do: 0
end
