defmodule SymphonyElixir.ExecutionFence.Persistence do
  @moduledoc """
  Durable, sanitized storage for the execution-fence state.

  The fence contract remains pure; this module owns the local durable boundary.
  Snapshots are encoded as versioned JSON and written through a synced temporary
  file before replacement. A malformed or incompatible snapshot is rejected so a
  restart fails closed instead of silently admitting stale ownership.
  """

  alias SymphonyElixir.ExecutionFence

  @schema_version 1

  @type load_result :: {:ok, ExecutionFence.state()} | :missing | {:error, term()}

  @spec load(Path.t()) :: load_result()
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        with {:ok, payload} <- Jason.decode(contents),
             {:ok, state} <- decode_state(payload),
             :ok <- ExecutionFence.validate(state) do
          {:ok, state}
        else
          {:error, reason} -> {:error, {:invalid_snapshot, reason}}
          other -> {:error, {:invalid_snapshot, other}}
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  @spec save(Path.t(), ExecutionFence.state()) :: :ok | {:error, term()}
  def save(path, state) when is_binary(path) do
    with :ok <- ExecutionFence.validate(state),
         {:ok, encoded} <- encode_state(state),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- atomic_write(path, encoded) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp encode_state(state) do
    Jason.encode(%{
      "schema_version" => @schema_version,
      "executions" => Map.new(state.executions, fn {issue_id, execution} -> {issue_id, encode_execution(execution)} end),
      "sessions" => Map.new(state.sessions, fn {session_id, session} -> {session_id, encode_lease(session)} end),
      "history" => Enum.map(state.history, &encode_execution/1)
    })
  end

  defp encode_execution(execution) do
    %{
      "issue_id" => execution.issue_id,
      "repository" => execution.repository,
      "generation" => execution.generation,
      "branch" => execution.branch,
      "worktree" => execution.worktree,
      "status" => Atom.to_string(execution.status),
      "ownership" => Atom.to_string(execution.ownership),
      "leases" => Map.new(execution.leases, fn {session_id, lease} -> {session_id, encode_lease(lease)} end),
      "terminal" => encode_terminal(execution.terminal),
      "cleanup" => Atom.to_string(execution.cleanup),
      "admitted_at_ms" => execution.admitted_at_ms,
      "cleaned_at_ms" => Map.get(execution, :cleaned_at_ms)
    }
  end

  defp encode_lease(lease) do
    %{
      "issue_id" => lease.issue_id,
      "repository" => lease.repository,
      "generation" => lease.generation,
      "role" => Atom.to_string(lease.role),
      "session_id" => lease.session_id,
      "process_id" => lease.process_id,
      "branch" => lease.branch,
      "worktree" => lease.worktree,
      "status" => Atom.to_string(lease.status),
      "registered_at_ms" => lease.registered_at_ms,
      "last_heartbeat_at" => lease.last_heartbeat_at,
      "linear_state" => lease.linear_state,
      "pr_state" => lease.pr_state,
      "head" => lease.head,
      "release_reason" => encode_optional_reason(Map.get(lease, :release_reason))
    }
  end

  defp encode_terminal(nil), do: nil

  defp encode_terminal(terminal) do
    %{
      "state" => terminal.state,
      "accepted_head" => terminal.accepted_head,
      "merge_identity" => terminal.merge_identity,
      "observed_at_ms" => terminal.observed_at_ms
    }
  end

  defp decode_state(%{"schema_version" => @schema_version, "executions" => executions, "sessions" => sessions, "history" => history})
       when is_map(executions) and is_map(sessions) and is_list(history) do
    with {:ok, decoded_executions} <- decode_map(executions, &decode_execution/1),
         {:ok, decoded_sessions} <- decode_map(sessions, &decode_lease/1),
         {:ok, decoded_history} <- decode_list(history, &decode_execution/1) do
      {:ok, %{schema_version: @schema_version, executions: decoded_executions, sessions: decoded_sessions, history: decoded_history}}
    end
  end

  defp decode_state(_payload), do: {:error, :unsupported_schema}

  defp decode_execution(payload) when is_map(payload) do
    with {:ok, issue_id} <- required(payload, "issue_id"),
         {:ok, repository} <- required(payload, "repository"),
         {:ok, generation} <- required(payload, "generation"),
         {:ok, branch} <- required(payload, "branch"),
         {:ok, worktree} <- required(payload, "worktree"),
         {:ok, status} <- decode_status(Map.get(payload, "status"), [:active, :terminal]),
         {:ok, ownership} <- decode_status(Map.get(payload, "ownership"), [:reconciled, :unknown, :contradictory]),
         {:ok, leases} <- decode_map(Map.get(payload, "leases"), &decode_lease/1),
         {:ok, terminal} <- decode_terminal(Map.get(payload, "terminal")),
         {:ok, cleanup} <- decode_status(Map.get(payload, "cleanup"), [:pending, :cleaned]),
         {:ok, admitted_at_ms} <- required(payload, "admitted_at_ms") do
      execution = %{
        issue_id: issue_id,
        repository: repository,
        generation: generation,
        branch: branch,
        worktree: worktree,
        status: status,
        ownership: ownership,
        leases: leases,
        terminal: terminal,
        cleanup: cleanup,
        admitted_at_ms: admitted_at_ms
      }

      {:ok, maybe_put_decoded(execution, :cleaned_at_ms, Map.get(payload, "cleaned_at_ms"))}
    end
  end

  defp decode_execution(_payload), do: {:error, :invalid_execution}

  defp decode_lease(payload) when is_map(payload) do
    with {:ok, issue_id} <- required(payload, "issue_id"),
         {:ok, repository} <- required(payload, "repository"),
         {:ok, generation} <- required(payload, "generation"),
         {:ok, role} <- decode_status(Map.get(payload, "role"), [:worker, :reviewer]),
         {:ok, session_id} <- required(payload, "session_id"),
         {:ok, process_id} <- required(payload, "process_id"),
         {:ok, branch} <- required(payload, "branch"),
         {:ok, worktree} <- required(payload, "worktree"),
         {:ok, status} <- decode_status(Map.get(payload, "status"), [:active, :released, :expired]),
         {:ok, registered_at_ms} <- required(payload, "registered_at_ms"),
         {:ok, last_heartbeat_at} <- required(payload, "last_heartbeat_at"),
         {:ok, linear_state} <- required(payload, "linear_state"),
         {:ok, pr_state} <- required(payload, "pr_state"),
         {:ok, head} <- required(payload, "head") do
      lease = %{
        issue_id: issue_id,
        repository: repository,
        generation: generation,
        role: role,
        session_id: session_id,
        process_id: process_id,
        branch: branch,
        worktree: worktree,
        status: status,
        registered_at_ms: registered_at_ms,
        last_heartbeat_at: last_heartbeat_at,
        linear_state: linear_state,
        pr_state: pr_state,
        head: head
      }

      {:ok, maybe_put_decoded(lease, :release_reason, Map.get(payload, "release_reason"))}
    end
  end

  defp decode_lease(_payload), do: {:error, :invalid_lease}

  defp decode_terminal(nil), do: {:ok, nil}

  defp decode_terminal(payload) when is_map(payload) do
    with {:ok, state} <- required(payload, "state"),
         {:ok, accepted_head} <- required(payload, "accepted_head"),
         {:ok, observed_at_ms} <- required(payload, "observed_at_ms") do
      {:ok,
       %{
         state: state,
         accepted_head: accepted_head,
         merge_identity: Map.get(payload, "merge_identity"),
         observed_at_ms: observed_at_ms
       }}
    end
  end

  defp decode_terminal(_payload), do: {:error, :invalid_terminal}

  defp decode_map(payload, decoder) when is_map(payload) do
    Enum.reduce_while(payload, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_binary(key) ->
        case decoder.(value) do
          {:ok, decoded} -> {:cont, {:ok, Map.put(acc, key, decoded)}}
          {:error, _reason} = error -> {:halt, error}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_map_key}}
    end)
  end

  defp decode_map(_payload, _decoder), do: {:error, :invalid_map}

  defp decode_list(payload, decoder) when is_list(payload) do
    Enum.reduce_while(payload, {:ok, []}, fn value, {:ok, acc} ->
      case decoder.(value) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp decode_status(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_status, value}}
      atom -> {:ok, atom}
    end
  end

  defp decode_status(_value, _allowed), do: {:error, :invalid_status}

  defp encode_optional_reason(nil), do: nil
  defp encode_optional_reason(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_optional_reason(value) when is_binary(value), do: value
  defp encode_optional_reason(_value), do: nil

  defp required(payload, key) do
    case Map.fetch(payload, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp maybe_put_decoded(map, _key, nil), do: map
  defp maybe_put_decoded(map, key, value), do: Map.put(map, key, value)

  defp atomic_write(path, contents) do
    temporary_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    result =
      with :ok <- write_synced(temporary_path, contents),
           :ok <- replace_file(temporary_path, path) do
        :ok
      end

    if result != :ok, do: File.rm(temporary_path)
    result
  end

  defp write_synced(path, contents) do
    case :file.open(String.to_charlist(path), [:write, :binary, :raw, :sync]) do
      {:ok, handle} ->
        try do
          :file.write(handle, contents)
        after
          :file.close(handle)
        end

      {:error, reason} ->
        {:error, {:write_failed, reason}}
    end
  end

  defp replace_file(temporary_path, path) do
    case File.rename(temporary_path, path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        with :ok <- File.rm(path), :ok <- File.rename(temporary_path, path) do
          :ok
        end

      {:error, reason} ->
        {:error, {:rename_failed, reason}}
    end
  end
end
