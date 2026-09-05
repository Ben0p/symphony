defmodule SymphonyElixir.GlobalPause do
  @moduledoc """
  Reads the operator-controlled global mutable-admission gate.

  A configured gate is fail-closed: only an exact `running` file value permits
  new mutable workers. Missing, unreadable, or invalid state is reported as
  paused. An unset path preserves the upstream runtime's unconfigured/test
  behavior; production pool launchers always provide the path.
  """

  @pause_file_env "SYMPHONY_GLOBAL_PAUSE_FILE"
  @running_state "running"
  @paused_state "paused"

  @type status :: %{
          configured?: boolean(),
          paused?: boolean(),
          state: String.t(),
          path: String.t() | nil,
          reason: String.t() | nil
        }

  @spec paused?() :: boolean()
  def paused?, do: snapshot().paused?

  @spec snapshot() :: status()
  def snapshot do
    case System.get_env(@pause_file_env) do
      path when is_binary(path) and path != "" ->
        read_state(Path.expand(path))

      _ ->
        %{
          configured?: false,
          paused?: false,
          state: "unconfigured",
          path: nil,
          reason: "missing_pause_file_path"
        }
    end
  end

  defp read_state(path) do
    case File.read(path) do
      {:ok, @running_state <> "\n"} -> running_status(path)
      {:ok, @running_state} -> running_status(path)
      {:ok, @paused_state <> "\n"} -> paused_status(path, "operator_paused")
      {:ok, @paused_state} -> paused_status(path, "operator_paused")
      {:ok, _contents} -> paused_status(path, "invalid_pause_file_state")
      {:error, reason} -> paused_status(path, Atom.to_string(reason))
    end
  end

  defp running_status(path) do
    %{configured?: true, paused?: false, state: @running_state, path: path, reason: nil}
  end

  defp paused_status(path, reason) do
    %{configured?: true, paused?: true, state: @paused_state, path: path, reason: reason}
  end
end
