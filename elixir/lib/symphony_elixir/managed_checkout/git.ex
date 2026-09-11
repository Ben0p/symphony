defmodule SymphonyElixir.ManagedCheckout.Git do
  @moduledoc false

  @timeout_ms 15_000
  @output_limit 65_536
  @redirected_env ~w(GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_NAMESPACE
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_COUNT
    GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM GIT_CONFIG_GLOBAL)

  @spec run(Path.t(), [String.t()]) :: {:ok, binary()} | {:error, term()}
  def run(cwd, args) do
    case System.find_executable("git") do
      nil -> {:error, :git_unavailable}
      executable -> start(executable, cwd, args)
    end
  end

  defp start(executable, cwd, args) do
    environment =
      Enum.map(@redirected_env, &{to_charlist(&1), false}) ++
        [{~c"GIT_TERMINAL_PROMPT", ~c"0"}, {~c"GIT_OPTIONAL_LOCKS", ~c"0"}]

    port =
      Port.open({:spawn_executable, to_charlist(executable)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, Enum.map(["--no-replace-objects", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null" | args], &to_charlist/1)},
        {:cd, to_charlist(cwd)},
        {:env, environment}
      ])

    collect(port, <<>>, System.monotonic_time(:millisecond) + @timeout_ms)
  rescue
    ArgumentError -> {:error, :git_start_failed}
  end

  defp collect(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when is_binary(data) ->
        if byte_size(output) + byte_size(data) > @output_limit do
          abort(port, :git_output_limit_requires_reconciliation)
        else
          collect(port, output <> data, deadline)
        end

      {^port, {:exit_status, 0}} ->
        {:ok, remove_final_newline(output)}

      {^port, {:exit_status, status}} ->
        {:error, {:git_failed, status}}
    after
      remaining ->
        abort(port, :git_timeout_requires_reconciliation)
    end
  end

  defp remove_final_newline(<<>>), do: <<>>

  defp remove_final_newline(output) do
    if :binary.last(output) == ?\n, do: binary_part(output, 0, byte_size(output) - 1), else: output
  end

  defp abort(port, reason) do
    close(port)
    # Closing a port does not prove OS process termination. Observe any available
    # exit status, otherwise retain an explicit hold for host reconciliation.
    case drain_exit(port, System.monotonic_time(:millisecond) + 1_000) do
      :exited -> {:error, reason}
      :unconfirmed -> {:error, {:git_process_termination_unconfirmed, reason}}
    end
  end

  defp drain_exit(port, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:exit_status, _}} -> :exited
      {^port, {:data, _}} -> drain_exit(port, deadline)
    after
      remaining -> :unconfirmed
    end
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
