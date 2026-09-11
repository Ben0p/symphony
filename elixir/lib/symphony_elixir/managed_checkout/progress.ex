defmodule SymphonyElixir.ManagedCheckout.Progress do
  @moduledoc false

  alias SymphonyElixir.ManagedCheckout.Git

  @ref_key :execution_checkout_progress_ref
  @owner_key :execution_checkout_progress_owner
  @identity_keys [:issue_id, :generation, :session_id, :repository, :worktree, :branch]
  @type result :: :ok | {:error, term()}

  @spec attach(binary(), keyword()) :: keyword()
  def attach(workspace, opts) do
    if enabled?(opts) and is_nil(Keyword.get(opts, @ref_key)) do
      ref = make_ref()
      identity = Keyword.get(opts, :execution_checkout)
      callback = Keyword.get(opts, :execution_checkout_checkpoint)

      Process.put({__MODULE__, ref}, %{
        ref: ref,
        owner: self(),
        workspace: workspace,
        identity: identity,
        callback: callback,
        head: nil,
        sequence: nil,
        status: setup_status(workspace, identity, callback)
      })

      opts |> Keyword.put(@ref_key, ref) |> Keyword.put(@owner_key, self())
    else
      opts
    end
  end

  @spec status(keyword()) :: result()
  def status(opts) do
    case locate(opts) do
      :legacy -> :ok
      {:ok, cursor} -> cursor.status
      {:error, _} = error -> error
    end
  end

  @spec observe(keyword(), term()) :: result()
  def observe(opts, verified) do
    with :ok <- status(opts) do
      case locate(opts) do
        :legacy -> :ok
        {:ok, cursor} -> observe_cursor(cursor, verified)
        {:error, _} = error -> error
      end
    end
  end

  @spec fail(keyword(), term()) :: result()
  def fail(opts, reason) do
    case locate(opts) do
      :legacy -> {:error, reason}
      {:ok, cursor} -> latch(cursor, reason)
      {:error, _} = error -> error
    end
  end

  @spec clear(keyword()) :: result()
  def clear(opts) do
    case locate(opts) do
      :legacy ->
        :ok

      {:ok, cursor} ->
        Process.delete({__MODULE__, cursor.ref})
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp enabled?(opts), do: not is_nil(Keyword.get(opts, :execution_checkout)) and not is_nil(Keyword.get(opts, :execution_checkout_checkpoint))

  defp setup_status(workspace, identity, callback) do
    cond do
      not is_function(callback, 1) -> {:error, :invalid_execution_checkout_checkpoint}
      not valid_identity?(identity) -> {:error, :invalid_execution_checkout_identity}
      identity.worktree != workspace -> {:error, :checkout_progress_workspace_mismatch}
      true -> :ok
    end
  end

  defp locate(opts) do
    case Keyword.get(opts, @ref_key) do
      nil -> if enabled?(opts), do: {:error, :missing_progress_cursor}, else: :legacy
      ref when is_reference(ref) -> owned_cursor(opts, ref)
      _ -> {:error, :invalid_progress_cursor_reference}
    end
  end

  defp owned_cursor(opts, ref) do
    if Keyword.get(opts, @owner_key) == self() do
      case Process.get({__MODULE__, ref}) do
        %{owner: owner, ref: ^ref} = cursor when owner == self() -> {:ok, cursor}
        _ -> {:error, :missing_progress_cursor}
      end
    else
      {:error, :progress_owner_mismatch}
    end
  end

  defp observe_cursor(cursor, %{head: head, branch: branch}) do
    cond do
      not valid_head?(head) or branch != cursor.identity.branch -> latch(cursor, :invalid_verified_checkout)
      is_nil(cursor.head) -> submit(cursor, :baseline, head, false, 0)
      cursor.head == head -> :ok
      true -> advance(cursor, head)
    end
  end

  defp observe_cursor(cursor, _verified), do: latch(cursor, :invalid_verified_checkout)

  defp advance(cursor, head) do
    with {:ok, _} <- Git.run(cursor.workspace, ["--no-replace-objects", "merge-base", "--is-ancestor", cursor.head, head]),
         {:ok, output} <- Git.run(cursor.workspace, ["--no-replace-objects", "rev-parse", "#{cursor.head}^{tree}", "#{head}^{tree}"]),
         {:ok, changed} <- changed_trees(output) do
      kind = if changed, do: :durable, else: :observed
      submit(cursor, kind, head, changed, cursor.sequence + 1)
    else
      {:error, reason} -> latch(cursor, reason)
    end
  end

  defp changed_trees(output) when is_binary(output) do
    case String.split(output, "\n") do
      [old, new] ->
        if valid_head?(old) and valid_head?(new), do: {:ok, old != new}, else: {:error, :invalid_git_tree_ids}

      _ ->
        {:error, :invalid_git_tree_output}
    end
  end

  defp submit(cursor, kind, head, changed, sequence) do
    checkpoint = %{kind: kind, sequence: sequence, previous_head: cursor.head, head: head, tree_changed: changed, identity: cursor.identity}

    case invoke(cursor.callback, checkpoint) do
      :ok ->
        Process.put({__MODULE__, cursor.ref}, %{cursor | head: head, sequence: sequence})
        :ok

      {:error, reason} ->
        latch(cursor, reason)
    end
  end

  defp invoke(callback, checkpoint) do
    case callback.(checkpoint) do
      :ok -> :ok
      {:error, _} = error -> error
      _ -> {:error, :invalid_progress_callback_result}
    end
  catch
    kind, reason -> {:error, {:checkout_progress_callback_failed, kind, reason}}
  end

  defp latch(%{status: :ok} = cursor, reason) do
    error = {:error, reason}
    Process.put({__MODULE__, cursor.ref}, %{cursor | status: error})
    error
  end

  defp latch(cursor, _reason), do: cursor.status

  defp valid_head?(head) when is_binary(head), do: Regex.match?(~r/\A[0-9a-f]{40}\z/, head)
  defp valid_head?(_head), do: false

  defp valid_identity?(identity) when is_map(identity) do
    Map.keys(identity) |> Enum.sort() == Enum.sort(@identity_keys) and
      is_integer(identity.generation) and identity.generation > 0 and
      Enum.all?([:issue_id, :session_id, :repository, :worktree, :branch], fn key ->
        value = Map.get(identity, key)
        is_binary(value) and byte_size(value) in 1..2_048
      end)
  end

  defp valid_identity?(_identity), do: false
end
