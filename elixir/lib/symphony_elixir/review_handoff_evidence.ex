defmodule SymphonyElixir.ReviewHandoffEvidence do
  @moduledoc "Reads current local Git and GitHub merge evidence for a stopped managed generation."

  alias SymphonyElixir.{PathSafety, ReviewHandoff, Workspace}

  @fields "number,url,state,headRefName,headRefOid,baseRefName,mergeCommit,mergedAt"
  @output_limit 262_144

  @spec observe(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def observe(execution, opts \\ []) do
    with %{worker_host: nil, worktree: workspace, repository: repository} <- execution,
         true <- is_binary(workspace) and is_binary(repository),
         {:ok, canonical} <- PathSafety.canonicalize(workspace),
         true <- canonical == Path.expand(workspace),
         {:ok, head} <- Workspace.current_head(workspace),
         {:ok, branch} <- read("git", ["branch", "--show-current"], workspace, opts),
         {:ok, status} <- read("git", ["status", "--porcelain=v1", "--untracked-files=all"], workspace, opts),
         {:ok, remote} <- read("git", ["remote", "get-url", "origin"], workspace, opts),
         true <- remote_matches?(remote, repository),
         {:ok, output} <- read("gh", pr_arguments(repository, branch), workspace, opts),
         {:ok, prs} when is_list(prs) and length(prs) < 100 <- Jason.decode(output) do
      snapshot = %{head: head, branch: branch, repository: repository, status: status}
      ReviewHandoff.accepted_merge(execution, snapshot, prs)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :review_merge_evidence_unavailable}
    end
  rescue
    _ -> {:error, :review_merge_evidence_unavailable}
  end

  defp pr_arguments(repository, branch) do
    ["pr", "list", "--repo", repository, "--state", "all", "--head", branch, "--limit", "100", "--json", @fields]
  end

  defp remote_matches?(remote, repository) do
    remote in ["https://github.com/#{repository}", "https://github.com/#{repository}.git", "git@github.com:#{repository}.git", "ssh://git@github.com/#{repository}.git"]
  end

  defp read(executable, args, workspace, opts) do
    runner = Keyword.get(opts, :command_runner, &bounded_command/3)

    case runner.(executable, args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} when is_binary(output) and byte_size(output) <= @output_limit ->
        {:ok, String.trim_trailing(output, "\n")}

      {_output, status} ->
        {:error, {:review_evidence_command_failed, executable, status}}
    end
  end

  # Managed archive qualification currently admits local Linux workers. GNU
  # timeout owns and terminates the command process group on this read-only path.
  defp bounded_command(executable, args, opts) do
    case :os.type() do
      {:unix, :linux} -> System.cmd("timeout", ["--kill-after=1s", "15s", executable | args], opts)
      _ -> {"", 126}
    end
  end
end
