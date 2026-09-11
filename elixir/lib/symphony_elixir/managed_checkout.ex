defmodule SymphonyElixir.ManagedCheckout do
  @moduledoc "Verifies local managed checkout identity; this is not an OS isolation boundary."

  alias SymphonyElixir.ManagedCheckout.Git
  alias SymphonyElixir.PathSafety

  @marker ".git/symphony-execution.json"
  @marker_limit 4_096
  @identity_keys [:issue_id, :generation, :session_id, :repository, :worktree, :branch]
  @type result :: {:ok, %{head: String.t(), branch: String.t()}} | {:error, term()}

  @spec prepare(Path.t(), map(), boolean()) :: result()
  def prepare(workspace, identity, created?), do: prepare(workspace, identity, created?, fn -> :ok end)

  @spec prepare(Path.t(), map(), boolean(), (-> :ok | {:error, term()})) :: result()
  def prepare(workspace, identity, false, guard) when is_function(guard, 0) do
    with :ok <- guard.(), {:ok, observed} <- verify(workspace, identity), :ok <- guard.(), do: {:ok, observed}
  end

  def prepare(workspace, identity, true, guard) when is_function(guard, 0) do
    with :ok <- guard.(),
         :ok <- validate_identity(identity),
         :ok <- validate_workspace(workspace, identity),
         :ok <- valid_branch(workspace, identity.branch),
         :ok <- git_layout(workspace, identity.repository),
         :ok <- expect(workspace, ["symbolic-ref", "--quiet", "--short", "HEAD"], "main"),
         :ok <- expect(workspace, ["rev-parse", "--is-shallow-repository"], "false"),
         :ok <- expect(workspace, ["config", "--get-all", "remote.origin.fetch"], "+refs/heads/*:refs/remotes/origin/*"),
         {:ok, base} <- head(workspace, "refs/remotes/origin/main^{commit}"),
         :ok <- expect(workspace, ["rev-parse", "--verify", "HEAD^{commit}"], base),
         :ok <- expect(workspace, ["status", "--porcelain=v1", "--untracked-files=all"], ""),
         :ok <- absent(Path.join(workspace, @marker)),
         :ok <- absent_ref(workspace, "refs/heads/#{identity.branch}"),
         :ok <- absent_ref(workspace, "refs/remotes/origin/#{identity.branch}"),
         :ok <- guard.(),
         {:ok, _} <- Git.run(workspace, ["-c", "core.hooksPath=/dev/null", "switch", "--no-guess", "--create", identity.branch, base]),
         :ok <- expect(workspace, ["symbolic-ref", "--quiet", "--short", "HEAD"], identity.branch),
         :ok <- expect(workspace, ["rev-parse", "--verify", "HEAD^{commit}"], base),
         :ok <- guard.(),
         :ok <- write_marker(workspace, identity, base),
         :ok <- guard.(),
         {:ok, observed} <- verify(workspace, identity),
         :ok <- guard.() do
      {:ok, observed}
    end
  end

  def prepare(_workspace, _identity, _created, _guard), do: {:error, :invalid_created_flag_or_guard}

  @spec verify(Path.t(), map()) :: result()
  def verify(workspace, identity) do
    with :ok <- validate_identity(identity),
         :ok <- validate_workspace(workspace, identity),
         :ok <- valid_branch(workspace, identity.branch),
         :ok <- git_layout(workspace, identity.repository),
         :ok <- expect(workspace, ["symbolic-ref", "--quiet", "--short", "HEAD"], identity.branch),
         {:ok, marker} <- read_marker(workspace),
         :ok <- marker_matches(marker, identity),
         {:ok, current_head} <- head(workspace, "HEAD^{commit}"),
         :ok <- expect(workspace, ["merge-base", "--is-ancestor", marker["base_head"], current_head], "") do
      {:ok, %{head: current_head, branch: identity.branch}}
    end
  end

  defp validate_identity(identity) when is_map(identity) do
    texts = [:issue_id, :session_id, :repository, :worktree, :branch]

    if Enum.all?(texts, &valid_text?(Map.get(identity, &1))) and
         is_integer(identity[:generation]) and identity.generation > 0 and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*\z/, identity.repository) do
      :ok
    else
      {:error, :managed_checkout_identity_invalid}
    end
  end

  defp validate_identity(_identity), do: {:error, :managed_checkout_identity_invalid}

  defp valid_text?(text) when is_binary(text) do
    byte_size(text) in 1..2_048 and String.valid?(text) and
      Enum.all?(:binary.bin_to_list(text), &(&1 > 31 and &1 != 127))
  end

  defp valid_text?(_text), do: false

  defp validate_workspace(workspace, identity) when is_binary(workspace) do
    with true <- Path.type(workspace) == :absolute and Path.expand(workspace) == workspace,
         true <- identity.worktree == workspace,
         {:ok, %File.Stat{type: :directory}} <- File.lstat(workspace),
         {:ok, ^workspace} <- PathSafety.canonicalize(workspace) do
      :ok
    else
      _ -> {:error, :managed_checkout_path_mismatch}
    end
  end

  defp validate_workspace(_workspace, _identity), do: {:error, :managed_checkout_path_mismatch}

  defp valid_branch(workspace, branch) do
    valid =
      byte_size(branch) <= 200 and branch not in ["main", "master", "HEAD"] and
        not String.starts_with?(branch, "refs/") and not String.contains?(branch, "@{") and
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/, branch)

    if valid do
      expect(workspace, ["check-ref-format", "--branch", branch], branch)
    else
      {:error, :managed_checkout_branch_invalid}
    end
  end

  defp git_layout(workspace, repository) do
    git = Path.join(workspace, ".git")

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(git),
         :ok <- absent(Path.join(git, "commondir")),
         :ok <- absent(Path.join(git, "gitdir")),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(Path.join(git, "objects")),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(Path.join(git, "objects/info")),
         :ok <- absent(Path.join(git, "objects/info/alternates")),
         :ok <- absent(Path.join(git, "objects/info/http-alternates")),
         :ok <- expect(workspace, ["rev-parse", "--show-toplevel"], workspace),
         :ok <- expect(workspace, ["rev-parse", "--absolute-git-dir"], git),
         :ok <- expect(workspace, ["config", "--get", "remote.origin.url"], "https://github.com/#{repository}.git") do
      :ok
    else
      _ -> {:error, :managed_checkout_repository_mismatch}
    end
  end

  defp absent(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _ -> {:error, :managed_checkout_path_exists_or_unreadable}
    end
  end

  defp absent_ref(workspace, ref) do
    case Git.run(workspace, ["show-ref", "--verify", "--quiet", ref]) do
      {:error, {:git_failed, 1}} -> :ok
      {:ok, _} -> {:error, :managed_checkout_branch_exists}
      error -> error
    end
  end

  defp marker_identity(identity) do
    identity |> Map.take(@identity_keys) |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp write_marker(workspace, identity, base) do
    marker = Map.merge(marker_identity(identity), %{"version" => 1, "base_head" => base})

    with {:ok, payload} <- Jason.encode(marker),
         true <- byte_size(payload) <= @marker_limit do
      exclusive_write(Path.join(workspace, @marker), payload)
    else
      _ -> {:error, :managed_checkout_marker_invalid}
    end
  end

  defp exclusive_write(path, payload) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        result = with :ok <- IO.binwrite(io, payload), do: :file.sync(io)
        closed = File.close(io)
        if result == :ok and closed == :ok, do: :ok, else: {:error, :managed_checkout_marker_write_failed}

      {:error, _} ->
        {:error, :managed_checkout_marker_exists_or_unwritable}
    end
  end

  defp read_marker(workspace) do
    path = Path.join(workspace, @marker)

    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         true <- size <= @marker_limit,
         {:ok, io} <- File.open(path, [:read, :binary]) do
      data =
        try do
          IO.binread(io, @marker_limit + 1)
        after
          File.close(io)
        end

      decode_marker(data)
    else
      _ -> {:error, :managed_checkout_marker_missing_or_invalid}
    end
  end

  defp decode_marker(data) when is_binary(data) and byte_size(data) <= @marker_limit do
    case Jason.decode(data) do
      {:ok, marker} when is_map(marker) ->
        if Jason.encode!(marker) == data, do: {:ok, marker}, else: {:error, :managed_checkout_marker_noncanonical}

      _ ->
        {:error, :managed_checkout_marker_invalid}
    end
  end

  defp decode_marker(_data), do: {:error, :managed_checkout_marker_invalid}

  defp marker_matches(marker, identity) do
    expected = Map.put(marker_identity(identity), "version", 1)

    if Map.drop(marker, ["base_head"]) == expected and valid_sha?(marker["base_head"]) do
      :ok
    else
      {:error, :managed_checkout_marker_identity_mismatch}
    end
  end

  defp head(workspace, ref) do
    case Git.run(workspace, ["rev-parse", "--verify", ref]) do
      {:ok, value} -> if valid_sha?(value), do: {:ok, value}, else: {:error, :managed_checkout_head_invalid}
      error -> error
    end
  end

  defp valid_sha?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{40}\z/, value)
  defp valid_sha?(_value), do: false

  defp expect(workspace, args, expected) do
    case Git.run(workspace, args) do
      {:ok, ^expected} -> :ok
      {:ok, _} -> {:error, :managed_checkout_git_identity_mismatch}
      error -> error
    end
  end
end
