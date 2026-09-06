defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = workspace_key(issue_or_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host) do
        case maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
          :ok ->
            {:ok, workspace}

          {:error, _reason} = error ->
            cleanup_failed_new_workspace(workspace, created?, worker_host)
            error
        end
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  @doc "Reads the exact Git commit currently checked out in a workspace."
  @spec current_head(Path.t()) :: {:ok, String.t()} | {:error, term()}
  @spec current_head(Path.t(), worker_host()) :: {:ok, String.t()} | {:error, term()}
  def current_head(workspace, worker_host \\ nil) do
    cond do
      is_binary(workspace) and is_nil(worker_host) -> current_local_head(workspace)
      is_binary(workspace) and is_binary(worker_host) -> current_remote_head(workspace, worker_host)
      true -> {:error, :invalid_workspace}
    end
  end

  defp current_local_head(workspace) do
    with :ok <- validate_workspace_path(workspace, nil) do
      try do
        case System.cmd("git", ["rev-parse", "--verify", "HEAD^{commit}"],
               cd: workspace,
               stderr_to_stdout: true
             ) do
          {output, 0} -> parse_git_head(output)
          {_output, status} -> {:error, {:git_head_unavailable, status}}
        end
      rescue
        error in [ArgumentError, ErlangError, File.Error] ->
          {:error, {:git_head_unavailable, error}}
      end
    end
  end

  defp current_remote_head(workspace, worker_host) do
    with :ok <- validate_workspace_path(workspace, worker_host),
         {:ok, {output, 0}} <-
           run_remote_command(
             worker_host,
             remote_shell_assign("workspace", workspace) <>
               "\ncd \"$workspace\" && git rev-parse --verify HEAD^{commit}",
             Config.settings!().hooks.timeout_ms
           ) do
      parse_git_head(output)
    else
      {:ok, {_output, status}} -> {:error, {:git_head_unavailable, status}}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            remove_local_workspace(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    case validate_remote_workspace_path(workspace) do
      :ok ->
        case maybe_run_before_remove_hook(workspace, worker_host) do
          :ok ->
            remove_remote_workspace(workspace, worker_host)

          {:error, reason} ->
            {:error, reason, workspace}
        end

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @doc false
  @spec remove_recorded(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_recorded(workspace, nil) when is_binary(workspace) do
    if Path.type(workspace) == :absolute do
      case validate_recorded_workspace_path(workspace) do
        :ok ->
          remove_local_workspace(workspace)

        {:error, reason} ->
          {:error, reason, ""}
      end
    else
      {:error, {:workspace_path_unreadable, workspace, :not_absolute}, ""}
    end
  end

  def remove_recorded(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    remove(workspace, worker_host)
  end

  def remove_recorded(workspace, _worker_host) do
    {:error, {:workspace_path_unreadable, workspace, :invalid}, ""}
  end

  @doc false
  @spec remote_cleanup_script_for_test(Path.t(), Path.t()) :: String.t()
  def remote_cleanup_script_for_test(workspace, root)
      when is_binary(workspace) and is_binary(root) do
    [
      "set -eu",
      remote_workspace_confinement_script(root, workspace),
      "rm -rf -- \"$workspace\""
    ]
    |> Enum.join("\n")
  end

  @doc false
  @spec path_exists?(Path.t(), worker_host()) :: {:ok, boolean()} | {:error, term()}
  def path_exists?(workspace, nil) when is_binary(workspace) do
    case File.lstat(workspace) do
      {:ok, _stat} -> {:ok, true}
      {:error, :enoent} -> {:ok, false}
      {:error, reason} -> {:error, {:workspace_presence_failed, reason}}
    end
  end

  def path_exists?(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    with :ok <- validate_remote_workspace_path(workspace),
         {:ok, {output, 0}} <-
           run_remote_command(
             worker_host,
             [
               "set -eu",
               remote_workspace_confinement_script(Config.settings!().workspace.root, workspace),
               "if [ -e \"$workspace\" ] || [ -L \"$workspace\" ]; then printf '1\\n'; else printf '0\\n'; fi"
             ]
             |> Enum.join("\n"),
             Config.settings!().hooks.timeout_ms
           ) do
      case String.trim(IO.iodata_to_binary(output)) do
        "1" -> {:ok, true}
        "0" -> {:ok, false}
        _ -> {:error, {:workspace_presence_failed, :invalid_output}}
      end
    else
      {:ok, {_output, status}} -> {:error, {:workspace_presence_failed, status}}
      {:error, _reason} = error -> error
    end
  end

  def path_exists?(_workspace, _worker_host), do: {:error, :invalid_workspace}

  defp remove_local_workspace(workspace) do
    case maybe_run_before_remove_hook(workspace, nil) do
      :ok ->
        case detach_local_reparse_points(workspace) do
          :ok -> File.rm_rf(workspace)
          {:error, reason} -> {:error, reason, workspace}
        end

      {:error, reason} ->
        {:error, reason, workspace}
    end
  end

  defp detach_local_reparse_points(workspace) do
    case :os.type() do
      {:win32, _name} ->
        detach_windows_reparse_points(workspace)

      _other ->
        :ok
    end
  end

  defp detach_windows_reparse_points(workspace) do
    case System.find_executable("pwsh") || System.find_executable("powershell.exe") do
      nil ->
        {:error, {:workspace_reparse_inspection_failed, workspace, :powershell_unavailable}}

      executable ->
        script = """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $root = [System.IO.Path]::GetFullPath($env:SYMPHONY_WORKSPACE).TrimEnd([char[]]('/\'))
        $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
        $pending = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
        $pending.Push([System.IO.DirectoryInfo]::new($root))
        while ($pending.Count -gt 0) {
          $directory = $pending.Pop()
          foreach ($entry in $directory.EnumerateFileSystemInfos('*', [System.IO.SearchOption]::TopDirectoryOnly)) {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
              $entryPath = [System.IO.Path]::GetFullPath($entry.FullName)
              if ($entryPath.Equals($root, [System.StringComparison]::OrdinalIgnoreCase) -or
                  -not $entryPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Reparse entry is outside the validated workspace: $entryPath"
              }

              $linkInfo = Get-Item -LiteralPath $entryPath -Force -ErrorAction Stop
              $linkType = [string]$linkInfo.LinkType
              if ($linkType -notin @('Junction', 'SymbolicLink')) {
                throw "Unsupported or unknown reparse entry type '$linkType': $entryPath"
              }

              $isDirectory = $linkInfo -is [System.IO.DirectoryInfo]
              $isFile = $linkInfo -is [System.IO.FileInfo]
              if (-not $isDirectory -and -not $isFile) {
                throw "Unable to determine reparse entry type: $entryPath"
              }

              # Native Delete receives only the link path and never the target;
              # the shell therefore cannot recurse through the reparse entry.
              if ($isDirectory) {
                [System.IO.Directory]::Delete($entryPath, $false)
              } else {
                [System.IO.File]::Delete($entryPath)
              }
              if ($null -ne (Get-Item -LiteralPath $entryPath -Force -ErrorAction SilentlyContinue)) {
                throw "Reparse entry remains after unlink: $entryPath"
              }
              continue
            }
            if ($entry -is [System.IO.DirectoryInfo]) {
              $pending.Push($entry)
            }
          }
        }
        """

        case System.cmd(executable, ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
               stderr_to_stdout: true,
               env: [{"SYMPHONY_WORKSPACE", workspace}]
             ) do
          {_output, 0} -> :ok
          {output, status} -> {:error, {:workspace_reparse_detach_failed, workspace, status, output}}
        end
    end
  rescue
    error -> {:error, {:workspace_reparse_inspection_failed, workspace, error.__struct__}}
  end

  defp remove_remote_workspace(workspace, worker_host) do
    root = Config.settings!().workspace.root
    script = remote_cleanup_script_for_test(workspace, root)

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> {:ok, []}
      {:ok, {output, status}} -> {:error, {:workspace_remove_failed, worker_host, status, output}, ""}
      {:error, reason} -> {:error, reason, ""}
    end
  end

  defp remove_startup_workspace(workspace, nil) do
    if File.exists?(workspace) do
      with :ok <- validate_workspace_path(workspace, nil) do
        with :ok <- maybe_run_before_remove_hook(workspace, nil) do
          with :ok <- detach_local_reparse_points(workspace) do
            # The hook already ran above. Remove directly so startup cleanup does
            # not invoke the before_remove hook a second time.
            remove_local_workspace_out_of_process(workspace)
          end
        end
      end
    else
      :ok
    end
  end

  defp remove_startup_workspace(workspace, worker_host) when is_binary(worker_host) do
    case remove(workspace, worker_host) do
      {:ok, _removed} -> :ok
      {:error, reason, path} -> {:error, {reason, path}}
    end
  end

  defp remove_local_workspace_out_of_process(workspace) do
    {executable, arguments} =
      case :os.type() do
        {:win32, _name} ->
          {"cmd.exe",
           [
             "/d",
             "/s",
             "/c",
             "rmdir",
             "/s",
             "/q",
             String.replace(workspace, "/", "\\")
           ]}

        _other ->
          {"rm", ["-rf", "--", workspace]}
      end

    case System.cmd(executable, arguments, stderr_to_stdout: true) do
      {_output, 0} ->
        if File.exists?(workspace),
          do: {:error, {:workspace_remove_incomplete, Path.basename(workspace)}},
          else: :ok

      {_output, status} ->
        {:error, {:workspace_remove_failed, status}}
    end
  rescue
    error -> {:error, {:workspace_remove_failed, error.__struct__}}
  end

  @spec remove_issue_workspaces(term()) :: :ok | {:error, term()}
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok | {:error, term()}
  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, worker_host)
      when is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(issue), worker_host) do
      {:ok, workspace} ->
        case remove(workspace, worker_host) do
          {:ok, _removed} -> :ok
          {:error, reason, path} -> {:error, {reason, path}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, nil) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(workspace_key(issue), nil) do
          {:ok, workspace} ->
            case remove(workspace, nil) do
              {:ok, _removed} -> :ok
              {:error, reason, path} -> {:error, {reason, path}}
            end

          {:error, reason} ->
            {:error, reason}
        end

      worker_hosts ->
        Enum.reduce_while(worker_hosts, :ok, fn worker_host, :ok ->
          case remove_issue_workspaces(issue, worker_host) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {worker_host, reason}}}
          end
        end)
    end
  end

  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(identifier), worker_host) do
      {:ok, workspace} ->
        case remove(workspace, worker_host) do
          {:ok, _removed} -> :ok
          {:error, reason, path} -> {:error, {reason, path}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(workspace_key(identifier), nil) do
          {:ok, workspace} ->
            case remove(workspace, nil) do
              {:ok, _removed} -> :ok
              {:error, reason, path} -> {:error, {reason, path}}
            end

          {:error, reason} ->
            {:error, reason}
        end

      worker_hosts ->
        Enum.reduce_while(worker_hosts, :ok, fn worker_host, :ok ->
          case remove_issue_workspaces(identifier, worker_host) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {worker_host, reason}}}
          end
        end)
    end
  end

  def remove_issue_workspaces(_identifier, _worker_host), do: :ok

  @doc false
  @spec remove_issue_workspaces_for_startup(term()) :: :ok | {:error, term()}
  def remove_issue_workspaces_for_startup(issue_or_identifier) do
    remove_issue_workspaces_for_startup(issue_or_identifier, nil)
  end

  @doc false
  @spec remove_issue_workspaces_for_startup(term(), worker_host()) :: :ok | {:error, term()}
  def remove_issue_workspaces_for_startup(issue_or_identifier, worker_host)
      when is_binary(worker_host) do
    with {:ok, workspace} <- workspace_path_for_issue(workspace_key(issue_or_identifier), worker_host) do
      remove_startup_workspace(workspace, worker_host)
    end
  end

  def remove_issue_workspaces_for_startup(%{identifier: identifier} = issue, nil)
      when is_binary(identifier),
      do: remove_valid_issue_workspaces_for_startup(issue)

  def remove_issue_workspaces_for_startup(identifier, nil) when is_binary(identifier),
    do: remove_valid_issue_workspaces_for_startup(identifier)

  def remove_issue_workspaces_for_startup(_issue_or_identifier, _worker_host),
    do: {:error, :invalid_issue_identifier}

  defp remove_valid_issue_workspaces_for_startup(issue_or_identifier) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        with {:ok, workspace} <- workspace_path_for_issue(workspace_key(issue_or_identifier), nil) do
          remove_startup_workspace(workspace, nil)
        end

      worker_hosts ->
        Enum.reduce_while(worker_hosts, :ok, fn worker_host, :ok ->
          case remove_issue_workspaces_for_startup(issue_or_identifier, worker_host) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
    end
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.local_workspace_root()
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  @doc """
  Returns the collision-safe directory name for an issue identifier.

  The hash is derived from the original identifier so callers that only know the identifier can
  derive the same key as callers holding a full tracker issue.
  """
  @spec workspace_key(map() | String.t() | nil) :: String.t()
  def workspace_key(%{identifier: identifier}), do: workspace_key(identifier)

  def workspace_key(identifier) when is_binary(identifier) do
    safe_identifier = safe_identifier(identifier)

    if safe_identifier == identifier do
      safe_identifier
    else
      "#{safe_identifier}--#{short_identifier_hash(identifier)}"
    end
  end

  def workspace_key(_identifier), do: "issue"

  defp safe_identifier(identifier) when is_binary(identifier),
    do: String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")

  defp short_identifier_hash(identifier) do
    :crypto.hash(:sha256, identifier)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp cleanup_failed_new_workspace(_workspace, false, _worker_host), do: :ok

  defp cleanup_failed_new_workspace(workspace, true, nil) do
    case File.rm_rf(workspace) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("Failed to remove partial workspace path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp cleanup_failed_new_workspace(workspace, true, worker_host) when is_binary(worker_host) do
    script = [remote_shell_assign("workspace", workspace), "rm -rf \"$workspace\""] |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      result ->
        Logger.warning("Failed to remove partial workspace worker_host=#{worker_host_for_log(worker_host)} result=#{inspect(result)}")
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            "set -eu",
            remote_workspace_confinement_script(Config.settings!().workspace.root, workspace),
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{command}", timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Config.local_workspace_root())
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp validate_recorded_workspace_path(workspace) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Path.dirname(workspace))
  end

  defp validate_remote_workspace_path(workspace) when is_binary(workspace) do
    root = Config.settings!().workspace.root

    with :ok <- validate_remote_path_text(workspace),
         :ok <- validate_remote_path_text(root),
         {:ok, root_segments} <- remote_path_segments(root),
         {:ok, workspace_segments} <- remote_path_segments(workspace),
         :ok <- validate_remote_absolute_path(workspace),
         :ok <- validate_remote_absolute_path(root) do
      if remote_path_kind(root) != remote_path_kind(workspace) or
           (length(workspace_segments) > length(root_segments) and
              Enum.take(workspace_segments, length(root_segments)) == root_segments) do
        :ok
      else
        {:error, {:workspace_outside_root, workspace, root}}
      end
    end
  end

  defp validate_remote_absolute_path(path) do
    normalized = String.replace(path, "\\", "/")

    if String.starts_with?(normalized, "/") or normalized == "~" or
         String.starts_with?(normalized, "~/") do
      :ok
    else
      {:error, {:workspace_path_unreadable, path, :not_absolute}}
    end
  end

  defp validate_remote_path_text(path) when is_binary(path) do
    cond do
      String.trim(path) == "" ->
        {:error, {:workspace_path_unreadable, path, :empty}}

      String.contains?(path, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, path, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_path_segments(path) when is_binary(path) do
    segments = String.split(String.replace(path, "\\", "/"), "/", trim: true)

    if Enum.any?(segments, &(&1 in [".", ".."])) do
      {:error, {:workspace_path_unreadable, path, :dot_segment}}
    else
      {:ok, segments}
    end
  end

  defp remote_path_kind(path) when is_binary(path) do
    normalized = String.replace(path, "\\", "/")
    if normalized == "~" or String.starts_with?(normalized, "~/"), do: :home, else: :absolute
  end

  defp remote_workspace_confinement_script(root, workspace)
       when is_binary(root) and is_binary(workspace) do
    [
      remote_shell_assign("root", root),
      remote_shell_assign("workspace", workspace),
      "if ! canonical_root=$(realpath -m -- \"$root\"); then exit 72; fi",
      "if ! canonical_workspace=$(realpath -m -- \"$workspace\"); then exit 72; fi",
      "case \"$canonical_workspace/\" in",
      "  \"$canonical_root/\"*) ;;",
      "  *) exit 73 ;;",
      "esac",
      "if [ \"$canonical_workspace\" = \"$canonical_root\" ]; then exit 74; fi"
    ]
    |> Enum.join("\n")
  end

  defp validate_local_workspace_path(workspace, workspace_root)
       when is_binary(workspace) and is_binary(workspace_root) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#\\~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp parse_git_head(output) do
    head = output |> IO.iodata_to_binary() |> String.trim()

    if Regex.match?(~r/\A[0-9a-f]{40,64}\z/, head) do
      {:ok, head}
    else
      {:error, :invalid_git_head}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
