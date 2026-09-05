defmodule SymphonyElixir.ExecutionSupervisor do
  @moduledoc """
  Linux process containment for one execution generation.

  A BEAM task or an Erlang port is only a transport handle; closing either one
  does not prove that descendants stopped. On admitted Linux workers this
  module launches the command in a systemd user scope with
  `KillMode=control-group`. Termination is successful only after systemd has
  stopped the unit and reports it inactive. Other platforms must supply an
  equivalent supervisor through the same boundary before their fence can be
  confirmed.
  """

  @systemd "systemd-run"
  @systemctl "systemctl"
  @unit_prefix "symphony-exec-"
  @max_unit_bytes 180

  @type identity :: %{
          supervisor: :systemd_user,
          unit: String.t(),
          session_id: String.t(),
          process_id: String.t(),
          issue_id: String.t(),
          generation: pos_integer(),
          launched_at_ms: non_neg_integer()
        }

  @type evidence :: %{
          process_tree: :terminated,
          supervisor: :systemd_user,
          unit: String.t(),
          session_id: String.t(),
          process_id: String.t(),
          pre_active_state: String.t() | nil,
          pre_control_group: String.t() | nil,
          pre_processes: [pos_integer()] | nil,
          main_pid: non_neg_integer() | nil,
          active_state: String.t(),
          control_group: String.t() | nil,
          remaining_processes: 0,
          observed_at_ms: non_neg_integer(),
          evidence_ref: String.t()
        }

  @doc "Returns the executable used for an admitted systemd user scope."
  @spec executable() :: String.t() | nil
  def executable, do: System.find_executable(@systemd)

  @doc "Returns whether the admitted Linux systemd user supervisor is available."
  @spec available?(keyword()) :: :ok | {:error, term()}
  def available?(opts \\ []) when is_list(opts) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    case run(command_runner, @systemctl, ["--user", "is-system-running"], opts) do
      {:ok, {output, 0}} when is_binary(output) ->
        if String.trim(output) in ["running", "degraded", "starting"], do: :ok, else: {:error, :systemd_user_unavailable}

      {:ok, {_output, status}} ->
        {:error, {:systemd_user_unavailable, status}}

      {:error, reason} ->
        {:error, {:systemd_user_unavailable, reason}}
    end
  end

  @doc "Builds a direct systemd-run argument vector for the admitted Linux path."
  @spec launch_args(String.t(), Path.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def launch_args(unit, cwd, command)
      when is_binary(unit) and is_binary(cwd) and is_binary(command) do
    with :ok <- validate_unit(unit),
         :ok <- validate_path(cwd),
         :ok <- validate_command(command) do
      {:ok,
       [
         "--user",
         "--scope",
         "--quiet",
         "--unit=#{unit}",
         "--property=KillMode=control-group",
         "--working-directory=#{cwd}",
         "--",
         "bash",
         "-lc",
         command
       ]}
    end
  end

  @doc "Creates the durable identity to persist beside the generation lease."
  @spec identity(String.t(), pos_integer(), String.t(), String.t(), non_neg_integer()) :: identity()
  def identity(issue_id, generation, session_id, process_id, launched_at_ms)
      when is_binary(issue_id) and is_integer(generation) and generation > 0 and
             is_binary(session_id) and is_binary(process_id) and is_integer(launched_at_ms) and
             launched_at_ms >= 0 do
    %{
      supervisor: :systemd_user,
      unit: unit_name(issue_id, generation, session_id),
      issue_id: issue_id,
      generation: generation,
      session_id: session_id,
      process_id: process_id,
      launched_at_ms: launched_at_ms
    }
  end

  @doc "Stops the persisted unit and returns proof that its containment boundary is inactive."
  @spec terminate(identity(), keyword()) :: {:ok, evidence()} | {:error, term()}
  def terminate(identity, opts \\ []) when is_map(identity) and is_list(opts) do
    with :ok <- validate_identity(identity) do
      case show_unit(identity.unit, opts) do
        {:ok, %{load_state: "not-found", active_state: active_state, control_group: nil}}
        when active_state in ["", "inactive", "unknown"] ->
          absent_unit_evidence(identity, opts)

        {:ok, %{load_state: "loaded", active_state: "inactive"} = unit_state} ->
          verify_inactive(identity, unit_state, opts)

        {:ok, unit_state} ->
          terminate_loaded_unit(identity, unit_state, opts)

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc "Validates the identity persisted with an execution generation."
  @spec validate(identity()) :: :ok | {:error, term()}
  def validate(identity) when is_map(identity), do: validate_identity(identity)
  def validate(_identity), do: {:error, :invalid_supervisor_identity}

  @doc "Validates persisted systemd identity and termination evidence as one tuple."
  @spec validate_evidence(identity(), map()) :: :ok | {:error, term()}
  def validate_evidence(identity, evidence) when is_map(identity) and is_map(evidence) do
    with :ok <- validate_identity(identity),
         true <- Map.get(evidence, :process_tree) == :terminated,
         true <- Map.get(evidence, :supervisor) == :systemd_user,
         true <- Map.get(evidence, :unit) == identity.unit,
         true <- Map.get(evidence, :session_id) == identity.session_id,
         true <- Map.get(evidence, :process_id) == identity.process_id,
         true <- Map.get(evidence, :active_state) == "inactive",
         true <- valid_pre_processes?(evidence),
         true <- Map.get(evidence, :remaining_processes) == 0,
         true <- is_binary(Map.get(evidence, :evidence_ref)),
         true <- is_integer(Map.get(evidence, :observed_at_ms)) and evidence.observed_at_ms >= identity.launched_at_ms do
      :ok
    else
      false -> {:error, :invalid_termination_evidence}
      {:error, _reason} = error -> error
    end
  end

  def validate_evidence(_identity, _evidence), do: {:error, :invalid_termination_evidence}

  defp valid_pre_processes?(%{control_group: nil, pre_processes: nil}), do: true

  defp valid_pre_processes?(%{pre_active_state: "inactive", pre_processes: processes})
       when is_list(processes),
       do: true

  defp valid_pre_processes?(%{pre_processes: processes}) when is_list(processes),
    do: processes != []

  defp valid_pre_processes?(_evidence), do: false

  @doc false
  @spec unit_name(String.t(), pos_integer(), String.t()) :: String.t()
  def unit_name(issue_id, generation, session_id)
      when is_binary(issue_id) and is_integer(generation) and generation > 0 and is_binary(session_id) do
    digest =
      :crypto.hash(:sha256, Enum.join([issue_id, Integer.to_string(generation), session_id], "\u0000"))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    String.slice(@unit_prefix <> digest, 0, @max_unit_bytes - byte_size(".scope")) <> ".scope"
  end

  defp command_runner(opts), do: Keyword.get(opts, :command_runner, &System.cmd/3)

  defp systemctl(runner, args, opts) do
    case run(runner, @systemctl, args, opts) do
      {:ok, {output, 0}} when is_binary(output) -> {:ok, output}
      {:ok, {_output, status}} -> {:error, {:systemd_command_failed, status}}
      {:error, reason} -> {:error, {:systemd_command_failed, reason}}
    end
  end

  defp terminate_loaded_unit(identity, unit_state, opts) do
    with :ok <- active_unit_for_stop(unit_state),
         {:ok, pre_processes} <- non_empty_control_group(unit_state.control_group, opts) do
      case systemctl(command_runner(opts), ["--user", "stop", "--wait", identity.unit], opts) do
        {:ok, _output} ->
          verify_stopped(identity, unit_state, pre_processes, opts)

        {:error, stop_error} = error ->
          # A restarted user manager may have discarded a retained scope after
          # the pre-stop observation. A failed stop is safe to reconcile only
          # when the exact unit is now absent and its cgroup is absent as well.
          case reconcile_absent_unit(identity, opts) do
            {:ok, evidence} -> {:ok, evidence}
            :not_absent -> error
            {:error, _reason} -> {:error, stop_error}
          end
      end
    end
  end

  defp reconcile_absent_unit(identity, opts) do
    case show_unit(identity.unit, opts) do
      {:ok, %{load_state: "not-found", active_state: active_state, control_group: nil}}
      when active_state in ["", "inactive", "unknown"] ->
        absent_unit_evidence(identity, opts)

      {:ok, _state} ->
        :not_absent

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp absent_unit_evidence(identity, opts) do
    with {:ok, now_ms} <- observed_at(opts) do
      {:ok, termination_evidence(identity, "inactive", nil, now_ms, nil)}
    end
  end

  defp verify_inactive(identity, unit_state, opts) do
    with {:ok, control_group} <- control_group(identity.unit, opts),
         :ok <- empty_control_group?(control_group, opts),
         {:ok, now_ms} <- observed_at(opts) do
      pre_state = Map.merge(unit_state, %{control_group: control_group, pre_processes: []})
      {:ok, termination_evidence(identity, "inactive", control_group, now_ms, pre_state)}
    end
  end

  defp show_unit(unit, opts) do
    case systemctl(
           command_runner(opts),
           ["--user", "show", "--property=LoadState,ActiveState,ControlGroup,MainPID", "--value", unit],
           opts
         ) do
      {:ok, output} ->
        case String.split(output, "\n", trim: false) do
          [load_state, active_state, control_group, main_pid | _] ->
            {:ok,
             %{
               load_state: String.trim(load_state),
               active_state: String.trim(active_state),
               control_group: blank_to_nil(control_group),
               main_pid: parse_pid(main_pid)
             }}

          _ ->
            {:error, :systemd_unit_state_missing}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp parse_pid(value) do
    case Integer.parse(String.trim(value)) do
      {pid, ""} when pid >= 0 -> pid
      _ -> nil
    end
  end

  defp active_unit_for_stop(%{load_state: "loaded", active_state: "active"}), do: :ok
  defp active_unit_for_stop(%{load_state: "loaded", active_state: state}), do: {:error, {:systemd_unit_not_active, state}}
  defp active_unit_for_stop(%{load_state: load_state}), do: {:error, {:systemd_unit_not_loaded, load_state}}

  defp non_empty_control_group(nil, _opts), do: {:error, :supervisor_cgroup_missing}

  defp non_empty_control_group(control_group, opts) when is_binary(control_group) do
    reader = Keyword.get(opts, :cgroup_reader, &read_cgroup_processes/1)

    case read_cgroup_processes_with(reader, control_group) do
      {:ok, []} -> {:error, :supervisor_cgroup_empty_before_stop}
      {:ok, processes} -> {:ok, processes}
      {:error, reason} -> {:error, {:cgroup_verification_failed, reason}}
    end
  rescue
    error -> {:error, {:cgroup_verification_failed, error}}
  end

  defp read_cgroup_processes_with(reader, control_group) do
    case reader.(control_group) do
      {:ok, processes} when is_list(processes) ->
        normalize_processes(processes)

      {:ok, contents} when is_binary(contents) ->
        normalize_processes(String.split(contents, "\n", trim: true))

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_cgroup_processes}
    end
  end

  defp normalize_processes(processes) do
    case Enum.reduce_while(processes, {:ok, []}, fn process, {:ok, acc} ->
           case process do
             pid when is_integer(pid) and pid > 0 ->
               {:cont, {:ok, [pid | acc]}}

             pid when is_binary(pid) ->
               case Integer.parse(String.trim(pid)) do
                 {pid, ""} when pid > 0 -> {:cont, {:ok, [pid | acc]}}
                 _ -> {:halt, {:error, :invalid_cgroup_processes}}
               end

             _ ->
               {:halt, {:error, :invalid_cgroup_processes}}
           end
         end) do
      {:ok, pids} -> {:ok, Enum.reverse(pids)}
      {:error, _reason} = error -> error
    end
  end

  defp verify_stopped(identity, unit_state, pre_processes, opts) do
    with {:ok, active_state} <- active_state(identity.unit, opts),
         :ok <- inactive_state(active_state),
         {:ok, control_group} <- control_group(identity.unit, opts),
         :ok <- empty_control_group?(control_group, opts),
         {:ok, now_ms} <- observed_at(opts) do
      {:ok, termination_evidence(identity, active_state, control_group, now_ms, Map.put(unit_state, :pre_processes, pre_processes))}
    end
  end

  defp termination_evidence(identity, active_state, control_group, now_ms, pre_state) do
    pre_state = pre_state || %{active_state: nil, control_group: nil, pre_processes: nil, main_pid: nil}

    %{
      process_tree: :terminated,
      supervisor: :systemd_user,
      unit: identity.unit,
      session_id: identity.session_id,
      process_id: identity.process_id,
      pre_active_state: pre_state.active_state,
      pre_control_group: pre_state.control_group,
      pre_processes: pre_state.pre_processes,
      main_pid: pre_state.main_pid,
      active_state: active_state,
      control_group: control_group,
      remaining_processes: 0,
      observed_at_ms: now_ms,
      evidence_ref: evidence_ref(identity, active_state, control_group)
    }
  end

  defp active_state(unit, opts) do
    with {:ok, output} <- systemctl(command_runner(opts), ["--user", "show", "--property=ActiveState", "--value", unit], opts),
         state when state != "" <- String.trim(output) do
      {:ok, state}
    else
      "" -> {:error, :systemd_active_state_missing}
      {:error, _reason} = error -> error
    end
  end

  defp control_group(unit, opts) do
    case systemctl(command_runner(opts), ["--user", "show", "--property=ControlGroup", "--value", unit], opts) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> {:ok, nil}
          value -> {:ok, value}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp inactive_state("inactive"), do: :ok
  defp inactive_state(_state), do: {:error, :systemd_unit_still_active}

  defp empty_control_group?(nil, _opts), do: :ok

  defp empty_control_group?(control_group, opts) when is_binary(control_group) do
    reader = Keyword.get(opts, :cgroup_reader, &read_cgroup_processes/1)

    case reader.(control_group) do
      {:ok, []} ->
        :ok

      {:ok, contents} when is_binary(contents) ->
        if String.trim(contents) == "", do: :ok, else: {:error, :processes_remain_in_supervisor}

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:cgroup_verification_failed, reason}}

      _ ->
        {:error, :processes_remain_in_supervisor}
    end
  rescue
    error -> {:error, {:cgroup_verification_failed, error}}
  end

  defp empty_control_group?(_control_group, _opts), do: {:error, :cgroup_verification_failed}

  defp read_cgroup_processes(control_group) do
    path = Path.join("/sys/fs/cgroup", String.trim_leading(control_group, "/") <> "/cgroup.procs")
    File.read(path)
  end

  defp observed_at(opts) do
    case Keyword.get(opts, :now_ms, System.system_time(:millisecond)) do
      now_ms when is_integer(now_ms) and now_ms >= 0 -> {:ok, now_ms}
      _ -> {:error, :invalid_observed_at}
    end
  end

  defp evidence_ref(identity, active_state, control_group) do
    seed = Enum.join([identity.unit, active_state, control_group || "none", Integer.to_string(identity.generation)], "\u0000")
    "systemd:" <> (:crypto.hash(:sha256, seed) |> Base.encode16(case: :lower))
  end

  defp run(runner, executable, args, opts) when is_function(runner, 3) do
    runner_opts = Keyword.get(opts, :system_cmd_opts, stderr_to_stdout: true)
    {:ok, runner.(executable, args, runner_opts)}
  rescue
    error -> {:error, {:systemd_runner_failed, error}}
  end

  defp run(_runner, _executable, _args, _opts), do: {:error, :invalid_command_runner}

  defp validate_identity(%{
         supervisor: :systemd_user,
         unit: unit,
         issue_id: issue_id,
         generation: generation,
         session_id: session_id,
         process_id: process_id,
         launched_at_ms: launched_at_ms
       }) do
    with :ok <- validate_unit(unit),
         true <- present?(issue_id),
         true <- is_integer(generation) and generation > 0,
         true <- present?(session_id),
         true <- present?(process_id),
         true <- is_integer(launched_at_ms) and launched_at_ms >= 0 do
      if unit == unit_name(issue_id, generation, session_id), do: :ok, else: {:error, :supervisor_identity_mismatch}
    else
      false -> {:error, :invalid_supervisor_identity}
      {:error, _reason} = error -> error
    end
  end

  defp validate_identity(_identity), do: {:error, :invalid_supervisor_identity}

  defp validate_unit(unit) when is_binary(unit) do
    if byte_size(unit) <= @max_unit_bytes and Regex.match?(~r/\Asymphony-exec-[a-f0-9]+\.scope\z/, unit),
      do: :ok,
      else: {:error, :invalid_supervisor_unit}
  end

  defp validate_unit(_unit), do: {:error, :invalid_supervisor_unit}

  defp validate_path(path), do: if(present?(path), do: :ok, else: {:error, :invalid_supervisor_cwd})
  defp validate_command(command), do: if(present?(command) and not String.contains?(command, ["\r", "\n", <<0>>]), do: :ok, else: {:error, :invalid_supervisor_command})
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
