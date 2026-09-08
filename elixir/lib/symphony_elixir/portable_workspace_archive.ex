defmodule SymphonyElixir.PortableWorkspaceArchive do
  @moduledoc """
  Copies workspace bytes while retaining links only as manifest metadata.

  Modes describe the source and remain evidence-bound metadata, allowing archives
  to be verified on another filesystem. Physical links are never accepted in v2.
  The caller must stop the writer; inventory checks do not isolate hostile code.
  """

  @spec copy(Path.t(), Path.t()) :: {:ok, [map()]} | {:error, term()}
  def copy(source, destination) do
    with {:ok, entries} <- inventory(source),
         :ok <- File.mkdir(destination),
         :ok <- materialize(source, destination, entries),
         :ok <- verify(destination, entries),
         {:ok, after_entries} <- inventory(source),
         true <- entries == after_entries do
      {:ok, entries}
    else
      false -> {:error, :cleanup_archive_state_changed}
      {:error, _reason} = error -> error
    end
  end

  @spec inventory(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def inventory(root) do
    with {:ok, entries} <- collect(root, true),
         :ok <- validate(entries) do
      {:ok, entries}
    end
  end

  @spec verify(Path.t(), [map()]) :: :ok | {:error, term()}
  def verify(root, entries) do
    with :ok <- validate(entries),
         {:ok, actual} <- collect(root, false),
         false <- Enum.any?(actual, &(&1["type"] == "symlink")),
         expected = Enum.reject(entries, &(&1["type"] == "symlink")),
         true <- physical_entries(expected) == physical_entries(actual) do
      :ok
    else
      value when is_boolean(value) -> {:error, :cleanup_archive_content_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp collect(root, skip_git) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} -> walk(root, "", skip_git)
      {:ok, _} -> {:error, :cleanup_archive_workspace_missing}
      {:error, reason} -> {:error, {:cleanup_archive_workspace_unreadable, reason}}
    end
  end

  defp walk(root, relative, skip_git) do
    with {:ok, names} <- File.ls(Path.join(root, relative)) do
      names = if skip_git and relative == "", do: Enum.reject(names, &(&1 == ".git")), else: names
      collect_children(root, relative, names)
    end
  end

  defp collect_children(root, relative, names) do
    names
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      child = if relative == "", do: name, else: relative <> "/" <> name

      case collect_entry(root, child) do
        {:ok, entries} -> {:cont, {:ok, [entries | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, nested} -> {:ok, nested |> List.flatten() |> Enum.sort_by(& &1["path"])}
      error -> error
    end
  end

  defp collect_entry(root, relative) do
    path = Path.join(root, relative)

    with :ok <- valid_path(relative),
         {:ok, stat} <- File.lstat(path) do
      read_entry(root, relative, path, stat)
    end
  end

  defp read_entry(root, relative, _path, %File.Stat{type: :directory, mode: mode}) do
    with {:ok, children} <- walk(root, relative, false) do
      {:ok, [%{"path" => relative, "type" => "directory", "mode" => mode} | children]}
    end
  end

  defp read_entry(_root, relative, path, %File.Stat{type: :regular, mode: mode}) do
    with {:ok, bytes} <- File.read(path) do
      {:ok, [%{"path" => relative, "type" => "regular", "mode" => mode, "size" => byte_size(bytes), "sha256" => digest(bytes)}]}
    end
  end

  defp read_entry(_root, relative, path, %File.Stat{type: :symlink}) do
    with {:ok, target} <- File.read_link(path) do
      {:ok, [%{"path" => relative, "type" => "symlink", "target" => target, "size" => byte_size(target), "sha256" => digest(target)}]}
    end
  end

  defp read_entry(_root, relative, _path, stat), do: {:error, {:cleanup_archive_special_file, relative, stat.type}}

  defp materialize(source, destination, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case copy_entry(source, destination, entry) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp copy_entry(_source, _destination, %{"type" => "symlink"}), do: :ok

  defp copy_entry(_source, destination, %{"type" => "directory", "path" => relative}),
    do: File.mkdir(Path.join(destination, relative))

  defp copy_entry(source, destination, %{"type" => "regular", "path" => relative} = entry) do
    path = Path.join(source, relative)

    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) == entry["size"] and digest(bytes) == entry["sha256"],
         :ok <- File.write(Path.join(destination, relative), bytes, [:binary, :exclusive]) do
      :ok
    else
      false -> {:error, :cleanup_archive_state_changed}
      {:ok, _stat} -> {:error, :cleanup_archive_state_changed}
      {:error, _reason} = error -> error
    end
  end

  defp validate(entries) when is_list(entries) do
    with :ok <- validate_shapes(entries) do
      paths = Enum.map(entries, & &1["path"])
      keys = Enum.map(paths, &path_key/1)
      types = Map.new(entries, &{path_key(&1["path"]), &1["type"]})

      if length(keys) == MapSet.size(MapSet.new(keys)) and
           Enum.all?(paths, &parents_are_directories?(&1, types)),
         do: :ok,
         else: {:error, :cleanup_archive_invalid_paths}
    end
  end

  defp validate(_entries), do: {:error, :cleanup_archive_invalid_entries}

  defp validate_shapes(entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case valid_entry(entry) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp valid_entry(%{"path" => path, "type" => "directory", "mode" => mode})
       when is_integer(mode) and mode >= 0,
       do: valid_path(path)

  defp valid_entry(%{"path" => path, "type" => "regular", "mode" => mode, "size" => size, "sha256" => sha})
       when is_integer(mode) and mode >= 0 and is_integer(size) and size >= 0 and is_binary(sha) do
    with :ok <- valid_path(path), do: valid_digest(sha)
  end

  defp valid_entry(%{"path" => path, "type" => "symlink", "target" => target, "size" => size, "sha256" => sha})
       when is_binary(target) and is_integer(size) and is_binary(sha) do
    with :ok <- valid_path(path),
         true <-
           String.valid?(target) and not String.contains?(target, <<0>>) and
             byte_size(target) == size and digest(target) == sha do
      :ok
    else
      false -> {:error, :cleanup_archive_invalid_link}
      {:error, _reason} = error -> error
    end
  end

  defp valid_entry(_entry), do: {:error, :cleanup_archive_invalid_entry}

  defp valid_path(path) when is_binary(path) do
    segments = String.split(path, "/")

    if String.valid?(path) and not String.contains?(path, [<<0>>, "\\", ":"]) and
         Enum.all?(segments, &(&1 not in ["", ".", ".."])) and hd(segments) != ".git",
       do: :ok,
       else: {:error, :cleanup_archive_invalid_path}
  end

  defp valid_path(_path), do: {:error, :cleanup_archive_invalid_path}

  defp parents_are_directories?(path, types) do
    case Path.dirname(path) do
      "." -> true
      parent -> Map.get(types, path_key(parent)) == "directory" and parents_are_directories?(parent, types)
    end
  end

  defp path_key(path) do
    case :os.type() do
      {:win32, _} -> String.downcase(path)
      _ -> path
    end
  end

  defp physical_entries(entries),
    do: entries |> Enum.map(&Map.delete(&1, "mode")) |> Enum.sort_by(& &1["path"])

  defp valid_digest(sha) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, sha), do: :ok, else: {:error, :cleanup_archive_invalid_digest}
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
