defmodule SymphonyElixir.WorkPackageClaim.Journal do
  @moduledoc """
  Private durable journal for work-package reservation replay.

  A reservation nonce is single-use state. The journal is written atomically
  before the provider claim so a lost response or process restart can replay
  the same reservation and authority tuple instead of creating a new one.
  """

  @schema_version 1

  @type reservation :: %{
          issue_id: String.t(),
          managed_project_profile_id: String.t(),
          repository_ref: String.t(),
          projection_id: String.t(),
          reservation_id: String.t(),
          reservation_nonce: String.t(),
          scope_keys: [String.t()],
          runner_id: String.t(),
          generation: pos_integer(),
          session_id: String.t(),
          process_id: String.t(),
          responsible_delegation_id: String.t(),
          execution_fence_token: String.t(),
          runtime_lease_id: String.t()
        }

  @type state :: %{schema_version: 1, reservations: %{optional(String.t()) => reservation()}}

  @spec load(Path.t()) :: {:ok, state()} | :missing | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> decode(contents)
      {:error, :enoent} -> recover_missing(path)
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  @spec put(state(), String.t(), reservation()) :: {:ok, state()} | {:error, term()}
  def put(%{schema_version: @schema_version, reservations: reservations} = state, key, reservation)
      when is_binary(key) and is_map(reservation) do
    {:ok, %{state | reservations: Map.put(reservations, key, reservation)}}
  end

  @spec new() :: state()
  def new, do: %{schema_version: @schema_version, reservations: %{}}

  @spec save(Path.t(), state()) :: :ok | {:error, term()}
  def save(path, %{schema_version: @schema_version, reservations: reservations} = state)
      when is_binary(path) and is_map(reservations) do
    with :ok <- validate(state),
         {:ok, encoded} <- Jason.encode(encode_state(state)),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- atomic_write(path, encoded) do
      _ = File.chmod(path, 0o600)
      :ok
    end
  end

  @spec validate(state()) :: :ok | {:error, term()}
  def validate(%{schema_version: @schema_version, reservations: reservations}) when is_map(reservations) do
    if Enum.all?(reservations, fn {key, reservation} -> is_binary(key) and valid_reservation?(reservation) end) do
      :ok
    else
      {:error, :invalid_journal}
    end
  end

  def validate(_state), do: {:error, :invalid_journal}

  defp decode(contents) do
    with {:ok, payload} <- Jason.decode(contents),
         {:ok, state} <- decode_state(payload),
         :ok <- validate(state) do
      {:ok, state}
    else
      {:error, reason} -> {:error, {:invalid_journal, reason}}
      _ -> {:error, :invalid_journal}
    end
  end

  defp decode_state(%{"schema_version" => @schema_version, "reservations" => reservations}) when is_map(reservations) do
    decoded =
      Enum.reduce_while(reservations, {:ok, %{}}, fn {key, payload}, {:ok, acc} ->
        case decode_reservation(payload) do
          {:ok, reservation} -> {:cont, {:ok, Map.put(acc, key, reservation)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case decoded do
      {:ok, reservations} -> {:ok, %{schema_version: @schema_version, reservations: reservations}}
      error -> error
    end
  end

  defp decode_state(_payload), do: {:error, :unsupported_schema}

  defp decode_reservation(payload) when is_map(payload) do
    fields = [
      {:issue_id, "issue_id"},
      {:managed_project_profile_id, "managed_project_profile_id"},
      {:repository_ref, "repository_ref"},
      {:projection_id, "projection_id"},
      {:reservation_id, "reservation_id"},
      {:reservation_nonce, "reservation_nonce"},
      {:runner_id, "runner_id"},
      {:session_id, "session_id"},
      {:process_id, "process_id"},
      {:responsible_delegation_id, "responsible_delegation_id"},
      {:execution_fence_token, "execution_fence_token"},
      {:runtime_lease_id, "runtime_lease_id"},
      {:generation, "generation"},
      {:scope_keys, "scope_keys"}
    ]

    with {:ok, values} <- required_fields(payload, fields),
         true <-
           Enum.all?(
             [
               :issue_id,
               :managed_project_profile_id,
               :repository_ref,
               :projection_id,
               :reservation_id,
               :reservation_nonce,
               :runner_id,
               :session_id,
               :process_id,
               :responsible_delegation_id,
               :execution_fence_token,
               :runtime_lease_id
             ],
             &present_string?(Map.get(values, &1))
           ),
         true <- is_integer(values.generation) and values.generation > 0,
         true <- is_list(values.scope_keys) and values.scope_keys != [] and Enum.all?(values.scope_keys, &present_string?/1) do
      {:ok, values}
    else
      false -> {:error, :invalid_reservation}
      error -> error
    end
  end

  defp decode_reservation(_payload), do: {:error, :invalid_reservation}

  defp required_fields(payload, fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {key, json_key}, {:ok, acc} ->
      case Map.fetch(payload, json_key) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :error -> {:halt, {:error, {:missing_field, json_key}}}
      end
    end)
  end

  defp valid_reservation?(reservation) when is_map(reservation) do
    string_fields = [
      :issue_id,
      :managed_project_profile_id,
      :repository_ref,
      :projection_id,
      :reservation_id,
      :reservation_nonce,
      :runner_id,
      :session_id,
      :process_id,
      :responsible_delegation_id,
      :execution_fence_token,
      :runtime_lease_id
    ]

    Enum.all?(string_fields, &present_string?(Map.get(reservation, &1))) and
      is_integer(reservation[:generation]) and reservation[:generation] > 0 and
      is_list(reservation[:scope_keys]) and reservation[:scope_keys] != [] and
      Enum.all?(reservation[:scope_keys], &present_string?/1)
  end

  defp valid_reservation?(_reservation), do: false

  defp recover_missing(path) do
    candidates = recovery_candidates(path)

    case candidates do
      [] ->
        :missing

      [candidate | _] ->
        read_recovery_candidate(candidate)
    end
  end

  defp recovery_candidates(path) do
    case File.ls(Path.dirname(path)) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&recovery_entry?(&1, Path.basename(path)))
        |> Enum.map(&Path.join(Path.dirname(path), &1))
        |> Enum.sort_by(&recovery_mtime/1, :desc)

      {:error, _reason} ->
        []
    end
  end

  defp recovery_entry?(entry, basename) do
    String.starts_with?(entry, basename <> ".tmp-") or
      String.starts_with?(entry, basename <> ".previous-")
  end

  defp read_recovery_candidate(candidate) do
    with {:ok, contents} <- File.read(candidate),
         {:ok, state} <- decode(contents) do
      recovery_state(candidate, state)
    else
      {:error, {:invalid_journal, reason}} ->
        {:error, {:invalid_recovery_journal, candidate, reason}}

      {:error, reason} ->
        {:error, {:recovery_read_failed, candidate, reason}}
    end
  end

  defp recovery_state(candidate, state) do
    if String.contains?(Path.basename(candidate), ".tmp-"),
      do: {:ok, state},
      else: {:error, {:journal_recovery_required, candidate}}
  end

  defp recovery_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  defp encode_state(%{schema_version: version, reservations: reservations}) do
    %{
      "schema_version" => version,
      "reservations" =>
        Map.new(reservations, fn {key, reservation} ->
          {key,
           Map.new(reservation, fn {field, value} ->
             {Atom.to_string(field), value}
           end)}
        end)
    }
  end

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp atomic_write(path, contents) do
    temporary_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    result =
      with :ok <- write_synced(temporary_path, contents),
           :ok <- replace_file(temporary_path, path) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end

    if result != :ok, do: File.rm(temporary_path)
    result
  end

  defp write_synced(path, contents) do
    case :file.open(String.to_charlist(path), [:write, :binary, :raw, :sync]) do
      {:ok, handle} ->
        chmod_result = File.chmod(path, 0o600)

        result = with :ok <- chmod_result, do: :file.write(handle, contents)

        try do
          result
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
        replace_existing_file(temporary_path, path)

      {:error, reason} ->
        {:error, {:rename_failed, reason}}
    end
  end

  defp replace_existing_file(temporary_path, path) do
    backup_path = "#{path}.previous-#{System.unique_integer([:positive])}"

    with :ok <- File.rename(path, backup_path),
         :ok <- File.rename(temporary_path, path) do
      _ = File.rm(backup_path)
      :ok
    else
      {:error, reason} -> restore_previous_file(backup_path, path, reason)
    end
  end

  defp restore_previous_file(backup_path, path, reason) do
    _ = File.rm(path)

    case File.rename(backup_path, path) do
      :ok ->
        {:error, {:rename_failed, reason}}

      {:error, restore_reason} ->
        {:error, {:rename_failed, reason, {:restore_failed, restore_reason}}}
    end
  end
end
