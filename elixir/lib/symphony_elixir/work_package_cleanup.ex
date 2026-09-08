defmodule SymphonyElixir.WorkPackageCleanup do
  @moduledoc """
  Preserves and verifies a work package before its workspace is removed.

  The archive is deliberately outside the active workspace root. It contains a
  copy of the workspace, the exact git state, and open pull request candidates;
  the before-remove hook is only one input to this record.
  """

  alias SymphonyElixir.{PathSafety, PortableWorkspaceArchive, Workspace}

  @archive_version 2

  @type target :: %{
          issue_id: String.t(),
          generation: pos_integer(),
          repository_ref: String.t(),
          branch: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          expected_head: String.t()
        }

  @doc "Archives the exact repository state before the workspace is removed."
  @spec prepare(map(), map(), String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def prepare(state, token, expected_head, entry, opts \\ [])
      when is_map(state) and is_map(token) and is_binary(expected_head) and is_map(entry) and is_list(opts) do
    with {:ok, target} <- target(state, token, expected_head, entry),
         :ok <- local_target(target),
         {:ok, archive_root} <- archive_root(opts),
         :ok <- archive_outside_workspace(archive_root, target.workspace),
         {:ok, observed_head} <- git_output(target.workspace, ["rev-parse", "HEAD"], opts),
         :ok <- exact_head(observed_head, expected_head),
         {:ok, git_state} <- collect_git_state(target.workspace, opts),
         {:ok, open_prs} <- collect_open_prs(target.branch, target.workspace, opts),
         metadata = build_metadata(target, git_state, open_prs),
         {:ok, evidence_ref} <- write_archive(archive_root, target, metadata, opts) do
      {:ok, evidence_ref}
    end
  end

  @doc "Verifies the preserved archive and the absence of the active workspace."
  @spec verify(map(), map(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def verify(state, token, expected_head, opts \\ [])
      when is_map(state) and is_map(token) and is_binary(expected_head) and is_list(opts) do
    with {:ok, target} <- target_from_state(state, token, expected_head),
         :ok <- local_target(target),
         {:ok, archive_root} <- archive_root(opts),
         :ok <- archive_outside_workspace(archive_root, target.workspace),
         {:ok, receipt} <- cleanup_receipt(state, token),
         {:ok, manifest} <- read_manifest(archive_root, target),
         :ok <- manifest_matches(manifest, target, expected_head, receipt),
         :ok <- verify_archive_contents(manifest, archive_root, target, opts),
         :ok <- workspace_absent?(target.workspace) do
      {:ok, receipt.evidence_ref}
    end
  end

  defp target(state, token, expected_head, entry) do
    with {:ok, target} <- target_from_state(state, token, expected_head) do
      workspace = Map.get(entry, :workspace_path) || target.workspace
      worker_host = Map.get(entry, :worker_host) || target.worker_host

      if is_binary(workspace) and Path.expand(workspace) == target.workspace and worker_host == target.worker_host,
        do: {:ok, target},
        else: {:error, :cleanup_target_missing}
    end
  end

  defp target_from_state(state, %{issue_id: issue_id, generation: generation}, expected_head)
       when is_binary(issue_id) and is_integer(generation) and generation > 0 do
    execution = get_in(Map.get(state, :execution_fence), [:executions, issue_id])

    if is_map(execution) and execution.generation == generation and is_binary(execution.worktree) and
         is_binary(execution.repository) and is_binary(execution.branch) do
      {:ok,
       %{
         issue_id: issue_id,
         generation: generation,
         repository_ref: execution.repository,
         branch: execution.branch,
         workspace: Path.expand(execution.worktree),
         worker_host: execution.worker_host,
         expected_head: expected_head
       }}
    else
      {:error, :cleanup_target_missing}
    end
  end

  defp target_from_state(_state, _token, _expected_head), do: {:error, :cleanup_target_missing}

  defp local_target(%{worker_host: nil}), do: :ok
  defp local_target(_target), do: {:error, :remote_cleanup_archive_unsupported}

  defp archive_root(opts) do
    case Keyword.get(opts, :archive_root) do
      root when is_binary(root) and root != "" -> {:ok, Path.expand(root)}
      _ -> {:error, :cleanup_archive_root_missing}
    end
  end

  defp archive_outside_workspace(archive_root, workspace) do
    with :ok <- File.mkdir_p(archive_root),
         {:ok, canonical_archive_root} <- PathSafety.canonicalize(archive_root),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace) do
      archive_prefix = canonical_archive_root <> "/"
      workspace_prefix = canonical_workspace <> "/"

      if canonical_archive_root != canonical_workspace and
           not String.starts_with?(archive_prefix, workspace_prefix),
         do: :ok,
         else: {:error, :cleanup_archive_inside_workspace}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_git_state(workspace, opts) do
    with {:ok, status} <- git_output(workspace, ["status", "--porcelain=v1", "--untracked-files=all"], opts),
         {:ok, staged_diff} <- git_output(workspace, ["diff", "--cached", "--binary"], opts),
         {:ok, unstaged_diff} <- git_output(workspace, ["diff", "--binary", "HEAD"], opts),
         {:ok, unmerged} <- git_output(workspace, ["ls-files", "--unmerged"], opts),
         {:ok, branch} <- git_output(workspace, ["branch", "--show-current"], opts) do
      {:ok,
       %{
         status: status,
         staged_diff: staged_diff,
         unstaged_diff: unstaged_diff,
         unmerged: unmerged,
         branch: branch
       }}
    end
  end

  defp collect_open_prs(branch, workspace, opts) do
    case command(opts).("gh", ["pr", "list", "--state", "open", "--head", branch, "--json", "number,url,reviewDecision,isDraft,headRefName"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} when is_binary(output) ->
        case Jason.decode(output) do
          {:ok, prs} when is_list(prs) -> {:ok, prs}
          _ -> {:error, :invalid_open_pr_candidates}
        end

      {_output, status} ->
        {:error, {:open_pr_query_failed, status}}
    end
  rescue
    error -> {:error, {:open_pr_query_failed, error}}
  end

  defp git_output(workspace, args, opts) do
    case command(opts).("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} when is_binary(output) -> {:ok, String.trim_trailing(output, "\n")}
      {_output, status} -> {:error, {:git_command_failed, args, status}}
    end
  rescue
    error -> {:error, {:git_command_failed, args, error}}
  end

  defp exact_head(observed_head, expected_head) when observed_head == expected_head, do: :ok
  defp exact_head(observed_head, expected_head), do: {:error, {:cleanup_head_changed, expected_head, observed_head}}

  defp build_metadata(target, git_state, open_prs) do
    %{
      archive_version: @archive_version,
      issue_id: target.issue_id,
      generation: target.generation,
      repository_ref: target.repository_ref,
      branch: target.branch,
      expected_head: target.expected_head,
      observed_head: target.expected_head,
      git: git_state,
      open_pull_requests: open_prs
    }
  end

  defp write_archive(archive_root, target, metadata, opts) do
    archive_dir = archive_dir(archive_root, target)
    manifest_path = Path.join(archive_dir, "manifest.json")
    staging_dir = archive_dir <> ".staging"

    cond do
      File.exists?(manifest_path) ->
        with {:ok, manifest} <- read_json(manifest_path),
             :ok <- manifest_matches_target(manifest, target),
             :ok <- current_archive_state_matches?(manifest, target, opts),
             :ok <- verify_archive_contents(manifest, archive_root, target, opts),
             :ok <- manifest_evidence_ref_matches(manifest),
             true <- is_binary(manifest["evidence_ref"]) and manifest["evidence_ref"] != "" do
          {:ok, manifest["evidence_ref"]}
        else
          false -> {:error, :cleanup_evidence_missing}
          {:error, _reason} = error -> error
        end

      File.exists?(archive_dir) ->
        {:error, :cleanup_archive_incomplete}

      true ->
        with {:ok, _removed} <- File.rm_rf(staging_dir),
             :ok <- File.mkdir_p(staging_dir),
             {:ok, workspace_files} <- PortableWorkspaceArchive.copy(target.workspace, Path.join(staging_dir, "workspace")),
             :ok <- create_repository_bundle(target.workspace, staging_dir, opts),
             {:ok, content} <- archive_content(staging_dir, workspace_files),
             final_metadata = Map.put(metadata, :content, content),
             :ok <- current_archive_state_matches?(Jason.decode!(Jason.encode!(final_metadata)), target, opts),
             evidence_ref = evidence_ref(final_metadata),
             :ok <- atomic_write(Path.join(staging_dir, "manifest.json"), Jason.encode!(Map.put(final_metadata, :evidence_ref, evidence_ref))),
             :ok <- File.rename(staging_dir, archive_dir),
             :ok <- verify_published_archive(archive_root, target, opts) do
          {:ok, evidence_ref}
        else
          {:error, reason} ->
            _ = File.rm_rf(staging_dir)
            {:error, {:cleanup_archive_build_failed, reason}}

          {:error, reason, path} ->
            {:error, {:cleanup_archive_staging_removal_failed, reason, path}}
        end
    end
  end

  defp read_manifest(archive_root, target) do
    path = Path.join(archive_dir(archive_root, target), "manifest.json")

    with {:ok, manifest} <- read_json(path),
         true <- File.dir?(Path.join(Path.dirname(path), "workspace")) do
      {:ok, manifest}
    else
      false -> {:error, :cleanup_archive_missing_workspace}
      {:error, _reason} = error -> error
    end
  end

  defp read_json(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, contents} ->
            case Jason.decode(contents) do
              {:ok, map} when is_map(map) -> {:ok, map}
              _ -> {:error, :invalid_cleanup_manifest}
            end

          {:error, reason} ->
            {:error, {:cleanup_manifest_unreadable, reason}}
        end

      {:ok, _stat} ->
        {:error, :invalid_cleanup_manifest}

      {:error, reason} ->
        {:error, {:cleanup_manifest_unreadable, reason}}
    end
  end

  defp manifest_matches(manifest, target, expected_head, receipt) do
    with :ok <- manifest_matches_target(manifest, target),
         true <- manifest["expected_head"] == expected_head,
         true <- manifest["observed_head"] == expected_head,
         true <- manifest["evidence_ref"] == receipt.evidence_ref,
         :ok <- manifest_evidence_ref_matches(manifest) do
      :ok
    else
      false -> {:error, :cleanup_manifest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp current_archive_state_matches?(manifest, target, opts) do
    with {:ok, observed_head} <- git_output(target.workspace, ["rev-parse", "HEAD"], opts),
         :ok <- exact_head(observed_head, target.expected_head),
         {:ok, git_state} <- collect_git_state(target.workspace, opts),
         {:ok, open_prs} <- collect_open_prs(target.branch, target.workspace, opts),
         {:ok, workspace_files} <- source_content_files(target.workspace, manifest["archive_version"]) do
      expected_git = Jason.decode!(Jason.encode!(git_state))
      expected_files = get_in(manifest, ["content", "workspace_files"])

      if manifest["git"] == expected_git and manifest["open_pull_requests"] == open_prs and
           expected_files == workspace_files,
         do: :ok,
         else: {:error, :cleanup_archive_state_changed}
    end
  end

  defp verify_archive_contents(manifest, archive_root, target, opts) do
    archive_dir = archive_dir(archive_root, target)
    content = manifest["content"]

    with {:ok, expected_files} <- content_files(content),
         :ok <- verify_workspace_content(Path.join(archive_dir, "workspace"), expected_files, manifest["archive_version"]),
         {:ok, bundle} <- content_bundle(content),
         :ok <- verify_file_digest(Path.join(archive_dir, bundle["path"]), bundle),
         :ok <- verify_repository_bundle(Path.join(archive_dir, bundle["path"]), target.expected_head, opts) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp verify_published_archive(archive_root, target, opts) do
    with {:ok, manifest} <- read_manifest(archive_root, target),
         :ok <- manifest_matches_target(manifest, target),
         :ok <- verify_archive_contents(manifest, archive_root, target, opts),
         :ok <- manifest_evidence_ref_matches(manifest) do
      :ok
    end
  end

  defp manifest_evidence_ref_matches(%{"evidence_ref" => evidence_ref} = manifest)
       when is_binary(evidence_ref) and evidence_ref != "" do
    if evidence_ref(Map.delete(manifest, "evidence_ref")) == evidence_ref,
      do: :ok,
      else: {:error, :cleanup_manifest_mismatch}
  end

  defp manifest_evidence_ref_matches(_manifest), do: {:error, :cleanup_manifest_mismatch}

  defp content_files(%{"workspace_files" => files}) when is_list(files), do: {:ok, files}
  defp content_files(_content), do: {:error, :cleanup_archive_content_missing}

  defp content_bundle(%{"repository_bundle" => bundle}) when is_map(bundle) do
    if bundle["path"] == "repository.bundle", do: {:ok, bundle}, else: {:error, :cleanup_archive_bundle_missing}
  end

  defp content_bundle(_content), do: {:error, :cleanup_archive_bundle_missing}

  defp archive_content(staging_dir, workspace_files) do
    with {:ok, bundle} <- file_digest(Path.join(staging_dir, "repository.bundle")) do
      bundle = bundle |> Map.put(:path, "repository.bundle") |> Map.put(:type, "regular")
      {:ok, %{workspace_files: workspace_files, repository_bundle: bundle}}
    end
  end

  defp source_content_files(workspace, 2), do: PortableWorkspaceArchive.inventory(workspace)
  defp source_content_files(workspace, 1), do: archive_content_files(workspace)

  defp verify_workspace_content(workspace, expected, 2), do: PortableWorkspaceArchive.verify(workspace, expected)

  defp verify_workspace_content(workspace, expected, 1) do
    with {:ok, actual} <- archive_content_files(workspace) do
      if expected == actual, do: :ok, else: {:error, :cleanup_archive_content_mismatch}
    end
  end

  defp archive_content_files(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} -> archive_content_entries(root, root, "")
      {:error, reason} -> {:error, {:cleanup_archive_workspace_unreadable, reason}}
      _ -> {:error, :cleanup_archive_workspace_missing}
    end
  end

  defp archive_content_entries(root, path, relative) do
    case File.ls(path) do
      {:ok, names} ->
        names = if relative == "", do: Enum.reject(names, &(&1 == ".git")), else: names

        case Enum.reduce_while(Enum.sort(names), {:ok, []}, fn name, {:ok, acc} ->
               child = Path.join(path, name)
               child_relative = if relative == "", do: name, else: Path.join(relative, name)

               case archive_content_entry(root, child, child_relative) do
                 {:ok, child_entries} -> {:cont, {:ok, acc ++ child_entries}}
                 {:error, _reason} = error -> {:halt, error}
               end
             end) do
          {:ok, entries} -> {:ok, Enum.sort_by(entries, & &1["path"])}
          {:error, reason} -> {:error, {:cleanup_archive_workspace_unreadable, reason}}
        end

      {:error, reason} ->
        {:error, {:cleanup_archive_workspace_unreadable, reason}}
    end
  end

  defp archive_content_entry(root, path, relative) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        archive_content_entries(root, path, relative)

      {:ok, %File.Stat{type: :regular} = stat} ->
        with {:ok, digest} <- file_digest(path) do
          {:ok, [%{"path" => normalize_relative_path(relative), "type" => "regular", "size" => digest.size, "sha256" => digest.sha256, "mode" => stat.mode}]}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(path) do
          {:ok, target} ->
            [%{"path" => normalize_relative_path(relative), "type" => "symlink", "target" => target, "sha256" => digest_bytes(target), "size" => byte_size(target)}]
            |> then(&{:ok, &1})

          {:error, reason} ->
            {:error, {:cleanup_archive_symlink_unreadable, reason}}
        end

      {:ok, stat} ->
        {:ok, [%{"path" => normalize_relative_path(relative), "type" => Atom.to_string(stat.type), "size" => stat.size, "mode" => stat.mode}]}

      {:error, reason} ->
        {:error, {:cleanup_archive_entry_unreadable, relative, reason}}
    end
  end

  defp file_digest(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, contents} ->
            {:ok, %{size: byte_size(contents), sha256: digest_bytes(contents)}}

          {:error, reason} ->
            {:error, {:cleanup_archive_file_unreadable, path, reason}}
        end

      {:ok, _stat} ->
        {:error, {:cleanup_archive_file_not_regular, path}}

      {:error, reason} ->
        {:error, {:cleanup_archive_file_unreadable, path, reason}}
    end
  end

  defp verify_file_digest(path, %{"type" => "regular", "size" => size, "sha256" => sha256}) do
    with {:ok, digest} <- file_digest(path),
         true <- digest.size == size and digest.sha256 == sha256 do
      :ok
    else
      false -> {:error, :cleanup_archive_file_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp verify_file_digest(path, %{"type" => "symlink", "target" => target, "size" => size, "sha256" => sha256}) do
    with {:ok, observed} <- File.read_link(path),
         true <- observed == target and byte_size(observed) == size and digest_bytes(observed) == sha256 do
      :ok
    else
      false -> {:error, :cleanup_archive_symlink_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp verify_file_digest(_path, _entry), do: :ok

  defp verify_repository_bundle(path, expected_head, opts) do
    recovery = Path.join(System.tmp_dir!(), "symphony-cleanup-bundle-#{System.unique_integer([:positive])}")

    try do
      case command(opts).("git", ["clone", "--quiet", path, recovery], cd: Path.dirname(path), stderr_to_stdout: true) do
        {_output, 0} ->
          case command(opts).("git", ["rev-parse", "HEAD"], cd: recovery, stderr_to_stdout: true) do
            {output, 0} when is_binary(output) ->
              if String.trim(output) == expected_head,
                do: :ok,
                else: {:error, :cleanup_archive_bundle_head_mismatch}

            {_output, status} ->
              {:error, {:cleanup_archive_bundle_invalid, status}}
          end

        {_output, status} ->
          {:error, {:cleanup_archive_bundle_invalid, status}}
      end
    after
      _ = File.rm_rf(recovery)
    end
  rescue
    error -> {:error, {:cleanup_archive_bundle_invalid, error}}
  end

  defp create_repository_bundle(workspace, archive_dir, opts) do
    bundle_path = Path.join(archive_dir, "repository.bundle")

    case command(opts).("git", ["bundle", "create", bundle_path, "--all"], cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, {:cleanup_archive_bundle_failed, status}}
    end
  rescue
    error -> {:error, {:cleanup_archive_bundle_failed, error}}
  end

  defp normalize_relative_path(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim_leading("./")
  end

  defp digest_bytes(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  defp manifest_matches_target(manifest, target) do
    if manifest["archive_version"] in [1, @archive_version] and manifest["issue_id"] == target.issue_id and
         manifest["generation"] == target.generation and manifest["repository_ref"] == target.repository_ref and
         manifest["branch"] == target.branch and manifest["expected_head"] == target.expected_head and
         manifest["observed_head"] == target.expected_head do
      :ok
    else
      {:error, :cleanup_manifest_mismatch}
    end
  end

  defp cleanup_receipt(state, token) do
    case get_in(Map.get(state, :execution_fence), [:executions, token.issue_id]) do
      %{generation: generation, cleanup_receipt: %{phase: phase, evidence_ref: evidence_ref}}
      when generation == token.generation and phase in [:removal_started, :verified] and is_binary(evidence_ref) ->
        {:ok, %{evidence_ref: evidence_ref}}

      _ ->
        {:error, :cleanup_evidence_missing}
    end
  end

  defp workspace_absent?(workspace) do
    case Workspace.path_exists?(workspace, nil) do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, :cleanup_workspace_still_present}
      {:error, _reason} = error -> error
    end
  end

  defp archive_dir(archive_root, target) do
    digest =
      :crypto.hash(:sha256, Enum.join([target.issue_id, Integer.to_string(target.generation), target.branch, target.expected_head], "\u0000"))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    Path.join(archive_root, "cleanup-" <> digest)
  end

  defp evidence_ref(metadata) do
    canonical = canonical_manifest_value(metadata)
    "sha256:" <> (:crypto.hash(:sha256, Jason.encode!(canonical)) |> Base.encode16(case: :lower))
  end

  defp canonical_manifest_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), canonical_manifest_value(nested)} end)
  end

  defp canonical_manifest_value(value) when is_list(value),
    do: Enum.map(value, &canonical_manifest_value/1)

  defp canonical_manifest_value(value), do: value

  defp command(opts), do: Keyword.get(opts, :command_runner, &System.cmd/3)

  defp atomic_write(path, contents) do
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.write(temporary, contents, [:binary]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, {:cleanup_manifest_write_failed, reason}}
    end
  end
end
