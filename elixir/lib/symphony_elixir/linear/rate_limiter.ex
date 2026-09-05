defmodule SymphonyElixir.Linear.RateLimiter do
  @moduledoc """
  Coordinates Linear requests across Symphony processes on one host.

  Each pool is a separate OS process, so an in-memory limiter cannot protect
  the shared Linear API key. A short-lived exclusive lock and a wall-clock
  reservation timestamp in a shared file provide a small host-local gate.
  Lock metadata records the owner OS process so stale cleanup cannot evict a
  live lock when its BEAM owner is briefly descheduled. Unix hosts with
  `flock` use a kernel-held lock that is released when the lock owner exits;
  the metadata protocol remains the fallback on other platforms.
  """

  require Logger

  @default_min_interval_ms 250
  @default_max_wait_ms 30_000
  @default_stale_lock_ms 5_000
  @default_max_retry_after_ms 3_600_000
  @lock_poll_ms 10
  @lock_metadata_version "symphony-linear-rate-lock-v1"
  @flock_ready_marker "symphony-linear-rate-lock-ready"
  @flock_unavailable_status 75

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

    case advisory_lock_executable() do
      executable when is_binary(executable) ->
        acquire_advisory_lock(settings, fun, executable, started_at)

      _missing ->
        acquire_token_lock(settings, fun, started_at)
    end
  end

  defp advisory_lock_executable do
    case :os.type() do
      {:unix, _name} -> System.find_executable("flock")
      _other -> nil
    end
  end

  defp acquire_advisory_lock(settings, fun, executable, started_at) do
    case open_advisory_lock(executable, settings.lock_path) do
      {:ok, port} ->
        case await_advisory_lock(port, started_at, settings.max_wait_ms, <<>>) do
          :ok ->
            result =
              try do
                fun.()
              after
                close_advisory_lock(port)
              end

            normalize_lock_result(result)

          {:error, :unavailable} ->
            close_advisory_lock(port)
            retry_advisory_lock(settings, fun, executable, started_at)

          {:error, reason} ->
            close_advisory_lock(port)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:linear_rate_limit_lock_open_failed, reason}}
    end
  end

  defp open_advisory_lock(executable, path) do
    command = "printf '#{@flock_ready_marker}'; cat"

    try do
      {:ok,
       Port.open(
         {:spawn_executable, executable},
         [:binary, :exit_status, {:args, ["-xn", "-E", Integer.to_string(@flock_unavailable_status), path, "-c", command]}]
       )}
    rescue
      error -> {:error, {:flock_unavailable, error}}
    end
  end

  defp await_advisory_lock(port, started_at, max_wait_ms, buffer) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    if elapsed_ms >= max_wait_ms do
      {:error, :unavailable}
    else
      timeout_ms = min(@lock_poll_ms * 2, max(max_wait_ms - elapsed_ms, 1))

      receive do
        {^port, {:data, data}} when is_binary(data) ->
          next_buffer = buffer <> data

          if String.starts_with?(next_buffer, @flock_ready_marker) do
            :ok
          else
            await_advisory_lock(port, started_at, max_wait_ms, next_buffer)
          end

        {^port, {:exit_status, @flock_unavailable_status}} ->
          {:error, :unavailable}

        {^port, {:exit_status, status}} ->
          {:error, {:flock_exit, status}}
      after
        timeout_ms -> {:error, :unavailable}
      end
    end
  end

  defp retry_advisory_lock(settings, fun, executable, started_at) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    if elapsed_ms >= settings.max_wait_ms do
      {:error, :linear_rate_limit_lock_timeout}
    else
      Process.sleep(min(@lock_poll_ms, settings.max_wait_ms - elapsed_ms))
      acquire_advisory_lock(settings, fun, executable, started_at)
    end
  end

  defp close_advisory_lock(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    _error -> :ok
  end

  defp normalize_lock_result({:error, reason}), do: {:error, reason}
  defp normalize_lock_result({:ok, value}), do: {:ok, value}
  defp normalize_lock_result(value), do: {:ok, value}

  defp acquire_token_lock(settings, fun, started_at) do
    case File.open(settings.lock_path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        lock_token = lock_token()

        result =
          try do
            with :ok <- write_lock_metadata(io, lock_token) do
              fun.()
            end
          after
            File.close(io)
            release_lock(settings.lock_path, lock_token)
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
            acquire_token_lock(settings, fun, started_at)

          true ->
            Process.sleep(@lock_poll_ms)
            acquire_token_lock(settings, fun, started_at)
        end

      {:error, reason} ->
        {:error, {:linear_rate_limit_lock_open_failed, reason}}
    end
  end

  defp stale_lock?(path, stale_lock_ms) do
    case File.read(path) do
      {:ok, content} ->
        case parse_lock_metadata(content) do
          {:ok, pid, created_at_ms} ->
            lock_expired?(created_at_ms, stale_lock_ms) and not pid_alive?(pid)

          # A newly-created lock can be observed before its metadata write if
          # its BEAM owner is descheduled. Treat incomplete or legacy locks as
          # live so that stale cleanup cannot evict an active reservation.
          :error ->
            false
        end

      {:error, _reason} ->
        false
    end
  end

  defp lock_token do
    [@lock_metadata_version, to_string(:os.getpid()), Integer.to_string(System.system_time(:millisecond)), Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)]
    |> Enum.join("\n")
  end

  defp write_lock_metadata(io, lock_token) do
    case IO.binwrite(io, lock_token) do
      :ok -> :ok
      {:error, reason} -> {:error, {:linear_rate_limit_lock_metadata_write_failed, reason}}
    end
  end

  defp release_lock(path, lock_token) do
    case File.read(path) do
      {:ok, ^lock_token} ->
        _ = File.rm(path)
        :ok

      _other ->
        :ok
    end
  end

  defp parse_lock_metadata(content) when is_binary(content) do
    case String.split(content, "\n", trim: true) do
      [@lock_metadata_version, pid, created_at_ms, _random_token] ->
        with {:ok, pid} <- parse_os_pid(pid),
             {created_at_ms, ""} <- Integer.parse(created_at_ms) do
          {:ok, pid, created_at_ms}
        else
          _ -> :error
        end

      _other ->
        :error
    end
  end

  defp parse_lock_metadata(_content), do: :error

  defp parse_os_pid(pid) do
    case Integer.parse(pid) do
      {pid, ""} when pid > 0 -> {:ok, Integer.to_string(pid)}
      _ -> :error
    end
  end

  defp lock_expired?(created_at_ms, stale_lock_ms) do
    System.system_time(:millisecond) - created_at_ms >= stale_lock_ms
  end

  defp pid_alive?(pid) when is_binary(pid) do
    case :os.type() do
      {:unix, _name} ->
        case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
          {_output, 0} -> true
          {_output, 1} -> false
          _other -> true
        end

      {:win32, _name} ->
        case System.cmd("tasklist", ["/FI", "PID eq #{pid}", "/NH"], stderr_to_stdout: true) do
          {output, 0} ->
            output
            |> String.downcase()
            |> then(&(not String.contains?(&1, "no tasks")))

          _other ->
            true
        end

      _other ->
        true
    end
  rescue
    _error -> true
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
