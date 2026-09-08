defmodule SymphonyElixir.PortableWorkspaceArchiveTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PortableWorkspaceArchive, as: Archive

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-portable-files-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}")
    source = Path.join(root, "source")
    File.mkdir_p!(Path.join(source, "nested/empty"))
    File.write!(Path.join(source, "nested/bytes.bin"), <<0, 255, 13, 10>>)
    destination = Path.join(root, "archive")
    on_exit(fn -> assert {:ok, _} = File.rm_rf(root) end)
    {:ok, root: root, source: source, destination: destination}
  end

  test "copies exact bytes and empty directories and retains source modes as portable metadata", context do
    assert {:ok, entries} = Archive.copy(context.source, context.destination)
    assert File.read!(Path.join(context.destination, "nested/bytes.bin")) == <<0, 255, 13, 10>>
    assert File.dir?(Path.join(context.destination, "nested/empty"))
    assert :ok = Archive.verify(context.destination, entries)
    assert Enum.all?(entries, &is_integer(&1["mode"]))
    alternate_modes = Enum.map(entries, &Map.put(&1, "mode", 0o600))
    assert :ok = Archive.verify(context.destination, alternate_modes)
    File.write!(Path.join(context.destination, "nested/bytes.bin"), "tampered")
    assert {:error, :cleanup_archive_content_mismatch} = Archive.verify(context.destination, entries)
  end

  test "rejects malformed and conflicting manifest paths before observing the destination", context do
    absent = Path.join(context.root, "absent")

    for path <- ["", "/absolute", "../escape", "nested/../escape", "a//b", "C:/escape", "a\\b", ".git/config", "a\u0000b"] do
      assert {:error, :cleanup_archive_invalid_path} = Archive.verify(absent, [%{"type" => "directory", "path" => path, "mode" => 0o755}])
    end

    directory = %{"type" => "directory", "path" => "a", "mode" => 0o755}
    assert {:error, :cleanup_archive_invalid_paths} = Archive.verify(absent, [directory, directory])
    assert {:error, :cleanup_archive_invalid_paths} = Archive.verify(absent, [%{directory | "path" => "missing/child"}])
    link = link_entry("a", "outside")
    assert {:error, :cleanup_archive_invalid_paths} = Archive.verify(absent, [link, %{directory | "path" => "a/child"}])

    if match?({:win32, _}, :os.type()) do
      assert {:error, :cleanup_archive_invalid_paths} = Archive.verify(absent, [directory, %{directory | "path" => "A"}])
    end
  end

  test "rejects malformed link metadata and a regular file in place of a virtual link", context do
    assert {:ok, entries} = Archive.copy(context.source, context.destination)
    link = link_entry("virtual-link", "../outside")
    assert :ok = Archive.verify(context.destination, [link | entries])
    assert {:error, :cleanup_archive_invalid_link} = Archive.verify(context.destination, [%{link | "size" => 999} | entries])
    assert {:error, :cleanup_archive_invalid_link} = Archive.verify(context.destination, [%{link | "sha256" => String.duplicate("0", 64)} | entries])
    File.write!(Path.join(context.destination, "virtual-link"), "unexpected")
    assert {:error, :cleanup_archive_content_mismatch} = Archive.verify(context.destination, [link | entries])
  end

  @tag skip: match?({:win32, _}, :os.type())
  test "retains relative and broken Unix links and rejects a physical link injected into the archive", context do
    assert :ok = File.ln_s("nested/bytes.bin", Path.join(context.source, "relative-link"))
    assert :ok = File.ln_s("../missing", Path.join(context.source, "broken-link"))
    assert {:ok, entries} = Archive.copy(context.source, context.destination)
    assert link_entry("relative-link", "nested/bytes.bin") in entries
    assert link_entry("broken-link", "../missing") in entries
    assert :ok = File.ln_s("../missing", Path.join(context.destination, "broken-link"))
    assert {:error, :cleanup_archive_content_mismatch} = Archive.verify(context.destination, entries)
  end

  @tag skip: match?({:win32, _}, :os.type())
  test "refuses special files without copying or opening them", context do
    assert {_, 0} = System.cmd("mkfifo", [Path.join(context.source, "fifo")])
    assert {:error, {:cleanup_archive_special_file, "fifo", _}} = Archive.copy(context.source, context.destination)
    refute File.exists?(context.destination)
  end

  defp link_entry(path, target) do
    %{"path" => path, "type" => "symlink", "target" => target, "size" => byte_size(target), "sha256" => :crypto.hash(:sha256, target) |> Base.encode16(case: :lower)}
  end
end
