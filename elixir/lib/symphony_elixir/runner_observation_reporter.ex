defmodule SymphonyElixir.RunnerObservationReporter do
  @moduledoc """
  Publishes a fixed, sanitized Symphony posture projection to Dahlia.

  This reporter is disabled unless all runner identity, call-home, and scoped
  execution-identity settings are present. It never calls a Symphony pool or
  sends the orchestrator's raw snapshot.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Orchestrator

  @default_interval_ms 5_000
  @max_interval_ms 60_000
  @snapshot_timeout_ms 5_000
  @max_queue_depth 10_000

  @type config :: %{
          url: String.t(),
          token: String.t(),
          runner_id: String.t(),
          managed_project_profile_id: String.t(),
          pool_key: String.t(),
          interval_ms: pos_integer(),
          state_path: Path.t(),
          responsible_delegation_id: String.t() | nil,
          execution_fence_id: String.t() | nil
        }

  @type post_fun :: (String.t(), keyword() -> {:ok, Req.Response.t()} | {:error, term()})

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec configuration(map()) :: {:ok, config()} | {:disabled, atom()} | {:error, atom()}
  def configuration(env) when is_map(env) do
    values = %{
      url: Map.get(env, :url),
      token: Map.get(env, :token),
      runner_id: Map.get(env, :runner_id),
      managed_project_profile_id: Map.get(env, :managed_project_profile_id),
      pool_key: Map.get(env, :pool_key),
      responsible_delegation_id: Map.get(env, :responsible_delegation_id),
      execution_fence_id: Map.get(env, :execution_fence_id),
      interval_ms: Map.get(env, :interval_ms, @default_interval_ms),
      state_path: Map.get(env, :state_path, default_state_path())
    }

    required = [:url, :token, :runner_id, :managed_project_profile_id, :pool_key]

    if Enum.any?(required, &blank?(Map.get(values, &1))) do
      {:disabled, :missing_configuration}
    else
      with {:ok, url} <- validate_url(values.url),
           {:ok, runner_id} <- required_identifier(values.runner_id),
           {:ok, profile_id} <- required_identifier(values.managed_project_profile_id),
           {:ok, pool_key} <- required_identifier(values.pool_key),
           {:ok, interval_ms} <- validate_interval(values.interval_ms),
           {:ok, state_path} <- validate_state_path(values.state_path),
           {:ok, token} <- required_secret(values.token),
           {:ok, delegation_id} <- optional_identifier(values.responsible_delegation_id),
           {:ok, fence_id} <- optional_identifier(values.execution_fence_id) do
        {:ok,
         %{
           url: url,
           token: token,
           runner_id: runner_id,
           managed_project_profile_id: profile_id,
           pool_key: pool_key,
           interval_ms: interval_ms,
           state_path: state_path,
           responsible_delegation_id: delegation_id,
           execution_fence_id: fence_id
         }}
      end
    end
  end

  @spec build_observation(map(), config(), non_neg_integer(), DateTime.t()) ::
          {:ok, map()} | {:error, atom()}
  def build_observation(snapshot, config, sequence, %DateTime{} = observed_at)
      when is_map(snapshot) and is_integer(sequence) and sequence >= 0 do
    running = list_value(snapshot, :running)
    retrying = list_value(snapshot, :retrying)
    blocked = list_value(snapshot, :blocked)
    {posture, active_run_id, active_run_count} = posture_projection(running, retrying, blocked)

    with {:ok, identity} <- execution_identity(active_run_count, config),
         {:ok, active_run_id} <- active_run_identifier(active_run_count, active_run_id) do
      {:ok,
       %{
         contractVersion: "symphony-runner-observation.v1",
         observationId: "#{config.runner_id}:#{sequence}",
         runnerId: config.runner_id,
         managedProjectProfileId: config.managed_project_profile_id,
         poolKey: config.pool_key,
         sequence: sequence,
         observedAt: DateTime.to_iso8601(DateTime.truncate(observed_at, :millisecond)),
         posture: posture,
         activeRunId: active_run_id,
         activeRunCount: active_run_count,
         queueDepth: min(length(retrying), @max_queue_depth),
         responsibleDelegationId: identity.responsible_delegation_id,
         executionFenceId: identity.execution_fence_id
       }}
    end
  end

  @impl true
  def init(opts) do
    configuration = Keyword.get(opts, :configuration, runtime_configuration())

    case configuration do
      {:ok, config} ->
        state = %{
          config: config,
          sequence: load_sequence(config.state_path),
          post_fun: Keyword.get(opts, :post_fun, &Req.post/2),
          orchestrator: Keyword.get(opts, :orchestrator, Orchestrator),
          snapshot_timeout_ms: Keyword.get(opts, :snapshot_timeout_ms, @snapshot_timeout_ms),
          timer_ref: nil
        }

        {:ok, schedule_report(state, 0)}

      {:disabled, _reason} ->
        :ignore

      {:error, reason} ->
        Logger.warning("Symphony runner call-home disabled: invalid configuration code=#{reason}")
        :ignore
    end
  end

  @impl true
  def handle_info(:report, state) do
    state = %{state | timer_ref: nil}
    next_sequence = state.sequence + 1

    snapshot = Orchestrator.snapshot(state.orchestrator, state.snapshot_timeout_ms)
    state = report_snapshot(snapshot, state, next_sequence)

    {:noreply, schedule_report(state, state.config.interval_ms)}
  end

  defp runtime_configuration do
    configuration(%{
      url: System.get_env("DAHLIA_RUNNER_CALL_HOME_URL"),
      token: System.get_env("DAHLIA_RUNNER_CALL_HOME_TOKEN"),
      runner_id: System.get_env("DAHLIA_RUNNER_ID"),
      managed_project_profile_id: System.get_env("DAHLIA_MANAGED_PROJECT_PROFILE_ID"),
      pool_key: System.get_env("DAHLIA_SYMPHONY_POOL_KEY"),
      responsible_delegation_id: System.get_env("DAHLIA_RESPONSIBLE_DELEGATION_ID"),
      execution_fence_id: System.get_env("DAHLIA_EXECUTION_FENCE_ID"),
      interval_ms: System.get_env("DAHLIA_RUNNER_OBSERVATION_INTERVAL_MS") |> parse_integer(@default_interval_ms),
      state_path: System.get_env("DAHLIA_RUNNER_OBSERVATION_STATE_PATH") || default_state_path()
    })
  end

  defp schedule_report(state, delay_ms) do
    if is_reference(state.timer_ref), do: Process.cancel_timer(state.timer_ref)
    %{state | timer_ref: Process.send_after(self(), :report, delay_ms)}
  end

  defp report_snapshot(snapshot, state, next_sequence) when is_map(snapshot) do
    case build_observation(snapshot, state.config, next_sequence, DateTime.utc_now()) do
      {:ok, observation} ->
        persist_and_post(state, next_sequence, observation)

      {:error, _reason} ->
        state
    end
  end

  defp report_snapshot(_snapshot, state, _next_sequence), do: state

  defp persist_and_post(state, next_sequence, observation) do
    case persist_sequence(state.config.state_path, next_sequence) do
      :ok ->
        post_observation(state.post_fun, state.config, observation)
        %{state | sequence: next_sequence}

      {:error, _reason} ->
        Logger.warning("Symphony runner call-home skipped: sequence persistence unavailable")
        state
    end
  end

  defp post_observation(post_fun, config, observation) do
    opts = [
      headers: [{"authorization", "Bearer #{config.token}"}, {"content-type", "application/json"}],
      json: observation,
      connect_options: [timeout: @snapshot_timeout_ms],
      receive_timeout: @snapshot_timeout_ms
    ]

    case post_fun.(config.url, opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Symphony runner call-home rejected: status=#{status}")

      {:error, _reason} ->
        Logger.warning("Symphony runner call-home unavailable")
    end
  rescue
    _error -> Logger.warning("Symphony runner call-home unavailable")
  end

  defp posture_projection([entry | _], _retrying, _blocked), do: {"running", Map.get(entry, :identifier) || Map.get(entry, "identifier"), 1}
  defp posture_projection([], [_entry | _], _blocked), do: {"starting", nil, 0}
  defp posture_projection([], [], [_entry | _]), do: {"blocked", nil, 0}
  defp posture_projection([], [], []), do: {"idle", nil, 0}

  defp execution_identity(0, _config), do: {:ok, %{responsible_delegation_id: nil, execution_fence_id: nil}}

  defp execution_identity(1, config) do
    if is_binary(config.responsible_delegation_id) and is_binary(config.execution_fence_id) do
      {:ok,
       %{
         responsible_delegation_id: config.responsible_delegation_id,
         execution_fence_id: config.execution_fence_id
       }}
    else
      {:error, :missing_execution_identity}
    end
  end

  defp active_run_identifier(0, nil), do: {:ok, nil}
  defp active_run_identifier(1, value), do: required_identifier(value)
  defp active_run_identifier(_count, _value), do: {:error, :active_run_identity_invalid}

  defp list_value(snapshot, key), do: if(is_list(Map.get(snapshot, key)), do: Map.get(snapshot, key), else: [])

  defp required_identifier(value) do
    if is_binary(value) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,239}$/u, value) and not unsafe_identifier?(value), do: {:ok, value}, else: {:error, :invalid_identifier}
  end

  defp optional_identifier(nil), do: {:ok, nil}
  defp optional_identifier(value), do: required_identifier(value)

  defp required_secret(value) when is_binary(value) and byte_size(value) > 0, do: {:ok, value}
  defp required_secret(_value), do: {:error, :missing_token}

  defp unsafe_identifier?(value), do: Regex.match?(~r/(secret|credential|password|token|authorization|cookie|private[_-]?key|prompt|completion|log|worktree)/iu, value)

  defp validate_url(value) when is_binary(value) do
    uri = URI.parse(value)
    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "", do: {:ok, value}, else: {:error, :invalid_url}
  end

  defp validate_url(_value), do: {:error, :invalid_url}

  defp validate_interval(value) when is_integer(value) and value > 0, do: {:ok, min(value, @max_interval_ms)}
  defp validate_interval(_value), do: {:error, :invalid_interval}

  defp validate_state_path(value) when is_binary(value) and byte_size(value) > 0, do: {:ok, value}
  defp validate_state_path(_value), do: {:error, :invalid_state_path}

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp parse_integer(_value, default), do: default

  defp default_state_path do
    state_root = System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
    Path.join(state_root, "symphony/runner-observation-sequence")
  end

  defp load_sequence(path) do
    case File.read(path) do
      {:ok, content} ->
        case Integer.parse(String.trim(content)) do
          {sequence, ""} when sequence >= 0 -> sequence
          _ -> 0
        end

      {:error, _reason} ->
        0
    end
  end

  defp persist_sequence(path, sequence) do
    temporary_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    result =
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(temporary_path, Integer.to_string(sequence), [:write, :binary]) do
        File.rename(temporary_path, path)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(temporary_path)
        {:error, reason}
    end
  end
end
