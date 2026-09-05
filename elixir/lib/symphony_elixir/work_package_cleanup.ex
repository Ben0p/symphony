defmodule SymphonyElixir.WorkPackageCleanup do
  @moduledoc """
  Preserves and verifies a work package before its workspace is removed.

  The archive is deliberately outside the active workspace root. It contains a
  copy of the workspace, the exact git state, and open pull request candidates;
  the before-remove hook is only one input to this record.
  """

  alias SymphonyElixir.{PathSafety, Workspace}

  @archive_version 1

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
         {:ok, evidence_ref} <- write_archive(archive_root, target, metadata),
         :ok <- persist_manifest_metadata(archive_root, target, metadata, evidence_ref) do
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
         :ok <- workspace_absent?(target.workspace) do
      {:ok, receipt.evidence_ref}
    end
  end

  defp target(state, %{issue_id: issue_id, generation: generation}, expected_head, entry)
       when is_binary(issue_id) and is_integer(generation) and generation > 0 do
    execution = get_in(Map.get(state, :execution_fence), [:executions, issue_id])
    workspace = Map.get(entry, :workspace_path) || get_in(execution, [:worktree])
    worker_host = Map.get(entry, :worker_host) || get_in(execution, [:worker_host])

    if is_map(execution) and is_binary(workspace) and is_binary(execution.repository) and
         is_binary(execution.branch) do
      {:ok,
       %{
         issue_id: issue_id,
         generation: generation,
         repository_ref: execution.repository,
         branch: execution.branch,
         workspace: Path.expand(workspace),
         worker_host: worker_host,
         expected_head: expected_head
       }}
    else
      {:error, :cleanup_target_missing}
    end
  end

  defp target(_state, _token, _expected_head, _entry), do: {:error, :cleanup_target_missing}

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

  defp write_archive(archive_root, target, metadata) do
    archive_dir = archive_dir(archive_root, target)
    manifest_path = Path.join(archive_dir, "manifest.json")
    workspace_archive = Path.join(archive_dir, "workspace")

    cond do
      File.exists?(manifest_path) ->
        with {:ok, manifest} <- read_json(manifest_path),
             :ok <- manifest_matches_target(manifest, target),
             true <- File.dir?(workspace_archive) do
          {:ok, manifest["evidence_ref"]}
        else
          false -> {:error, :cleanup_archive_missing_workspace}
          {:error, _reason} = error -> error
        end

      File.exists?(archive_dir) ->
        {:error, :cleanup_archive_incomplete}

      true ->
        with :ok <- File.mkdir_p(archive_dir),
             {:ok, _files} <- File.cp_r(target.workspace, workspace_archive) do
          evidence_ref = evidence_ref(metadata)
          {:ok, evidence_ref}
        else
          {:error, reason} -> {:error, {:cleanup_archive_copy_failed, reason}}
        end
    end
  end

  defp persist_manifest_metadata(archive_root, target, metadata, evidence_ref) do
    archive_dir = archive_dir(archive_root, target)
    manifest = Map.put(metadata, :evidence_ref, evidence_ref)
    atomic_write(Path.join(archive_dir, "manifest.json"), Jason.encode!(manifest))
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
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> {:error, :invalid_cleanup_manifest}
        end

      {:error, reason} ->
        {:error, {:cleanup_manifest_unreadable, reason}}
    end
  end

  defp manifest_matches(manifest, target, expected_head, receipt) do
    with :ok <- manifest_matches_target(manifest, target),
         true <- manifest["expected_head"] == expected_head,
         true <- manifest["observed_head"] == expected_head,
         true <- manifest["evidence_ref"] == receipt.evidence_ref do
      :ok
    else
      false -> {:error, :cleanup_manifest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp manifest_matches_target(manifest, target) do
    if manifest["archive_version"] == @archive_version and manifest["issue_id"] == target.issue_id and
         manifest["generation"] == target.generation and manifest["repository_ref"] == target.repository_ref and
         manifest["branch"] == target.branch do
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
    "sha256:" <> (:crypto.hash(:sha256, Jason.encode!(metadata)) |> Base.encode16(case: :lower))
  end

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
