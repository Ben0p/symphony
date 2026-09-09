defmodule SymphonyElixir.Codex.Progress do
  @moduledoc """
  Recognizes completed app-server file changes for the current running session.

  The bounded, attempt-local identity set is an observation dedupe, not execution authority.
  Saturation fails closed without evicting identities that could later be replayed.
  """

  @max_seen_file_changes 1_024

  @spec accept_file_change(term(), term(), term(), MapSet.t()) ::
          {:accepted, MapSet.t()} | {:ignored, MapSet.t()}
  def accept_file_change(update, current_session, workspace, seen) do
    with %{
           event: :notification,
           payload: %{
             "method" => "item/completed",
             "params" => %{
               "threadId" => thread,
               "turnId" => turn,
               "item" => %{
                 "type" => "fileChange",
                 "status" => "completed",
                 "id" => item_id,
                 "changes" => changes
               }
             }
           }
         } <- update,
         true <- Enum.all?([thread, turn, item_id], &nonempty_text?/1),
         %{id: session_id, thread_id: ^thread, turn_id: ^turn} <- current_session,
         true <- session_id == thread <> "-" <> turn,
         key = {thread, turn, item_id},
         false <- MapSet.member?(seen, key),
         true <- MapSet.size(seen) < @max_seen_file_changes,
         true <- is_list(changes) and changes != [],
         true <- Enum.all?(changes, &valid_change?(&1, workspace)) do
      {:accepted, MapSet.put(seen, key)}
    else
      _ -> {:ignored, seen}
    end
  end

  defp valid_change?(%{"path" => path, "diff" => diff, "kind" => %{"type" => type} = kind}, workspace)
       when type in ["add", "update", "delete"] do
    nonempty_text?(diff) and within_workspace?(path, workspace) and
      (is_nil(kind["move_path"]) or within_workspace?(kind["move_path"], workspace))
  end

  defp valid_change?(_, _), do: false

  # This is lexical event validation. Workspace ownership and filesystem containment
  # remain enforced by the execution boundary; notifications grant no authority.
  defp within_workspace?(path, workspace) do
    with true <- nonempty_text?(path) and nonempty_text?(workspace),
         :absolute <- Path.type(path),
         :absolute <- Path.type(workspace) do
      relative = Path.relative_to(Path.expand(path), Path.expand(workspace))

      Path.type(relative) == :relative and relative not in [".", ".."] and
        not String.starts_with?(relative, "../") and not String.starts_with?(relative, "..\\")
    else
      _ -> false
    end
  end

  defp nonempty_text?(value) when is_binary(value),
    do: String.valid?(value) and String.trim(value) != "" and not String.contains?(value, <<0>>)

  defp nonempty_text?(_), do: false
end
