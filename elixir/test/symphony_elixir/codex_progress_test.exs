defmodule SymphonyElixir.Codex.ProgressTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.Progress

  @workspace "/workspace/task"
  @session %{id: "thread-turn", thread_id: "thread", turn_id: "turn"}

  test "accepts the observed completed add and update shapes and completed deletion" do
    for kind <- ["add", "update", "delete"] do
      assert {:accepted, seen} = accept(update(kind: %{"type" => kind, "move_path" => nil}))
      assert MapSet.member?(seen, {"thread", "turn", "exec-id"})
    end
  end

  test "rejects unrelated, incomplete, failed, declined, malformed and empty changes" do
    for invalid <- [
          nil,
          %{},
          update(method: "item/started"),
          update(method: "item/fileChange/requestApproval"),
          update(type: "commandExecution"),
          update(status: "inProgress"),
          update(status: "failed"),
          update(status: "declined"),
          update(id: ""),
          update(id: nil),
          update(changes: []),
          update(changes: nil),
          update(changes: [%{}]),
          update(diff: ""),
          update(diff: "  \n"),
          update(kind: "add"),
          update(kind: %{"type" => "rename"})
        ] do
      assert {:ignored, %MapSet{}} = accept(invalid)
    end
  end

  test "requires both current session identifiers and rejects old events after restart" do
    for invalid <- [update(thread: nil), update(turn: ""), update(thread: "old"), update(turn: "old")] do
      assert {:ignored, %MapSet{}} = accept(invalid)
    end

    assert {:ignored, %MapSet{}} = accept(update(), nil)
    assert {:ignored, %MapSet{}} = accept(update(), "thread")
    assert {:ignored, %MapSet{}} = accept(update(), "new-thread-new-turn")
    next_session = %{id: "new-thread-new-turn", thread_id: "new-thread", turn_id: "new-turn"}
    assert {:accepted, _} = accept(update(thread: "new-thread", turn: "new-turn"), next_session)
    assert {:ignored, %MapSet{}} = accept(update(), next_session)
  end

  test "joined session IDs cannot hide different thread and turn boundaries" do
    session = %{id: "t-a-b", thread_id: "t-a", turn_id: "b"}
    assert {:ignored, %MapSet{}} = accept(update(thread: "t", turn: "a-b"), session)
    assert {:accepted, _} = accept(update(thread: "t-a", turn: "b"), session)
  end

  test "every changed path and move path must be a file lexically inside the workspace" do
    for path <- [nil, "", "relative/file", @workspace, "/outside/file", "/workspace/task-other/file", "/workspace/task/../other/file", "/workspace/task/../../file"] do
      assert {:ignored, %MapSet{}} = accept(update(path: path))
    end

    assert {:ignored, %MapSet{}} = accept(update(kind: %{"type" => "update", "move_path" => "/outside/file"}))
    assert {:accepted, _} = accept(update(path: "/workspace/task/sub/../file"))
    assert {:ignored, %MapSet{}} = Progress.accept_file_change(update(), @session, nil, MapSet.new())

    changes = [change(), Map.put(change(), "path", "/outside/file")]
    assert {:ignored, %MapSet{}} = accept(update(changes: changes))
  end

  test "duplicate and conflicting reused identities never reset progress" do
    {:accepted, seen} = accept(update())
    assert {:ignored, ^seen} = accept(update(), @session, seen)
    assert {:ignored, ^seen} = accept(update(diff: "+different"), @session, seen)
    assert {:ignored, ^seen} = accept(update(path: "/outside"), @session, seen)
    assert {:accepted, _} = accept(update(id: "next-item"), @session, seen)
  end

  test "saturation is fail closed without evicting old identities" do
    seen = MapSet.new(1..1_024, &{"thread", "turn", "item-#{&1}"})
    assert {:ignored, ^seen} = accept(update(), @session, seen)
    assert {:ignored, ^seen} = accept(update(id: "item-1"), @session, seen)
  end

  defp accept(update, session \\ @session, seen \\ MapSet.new()),
    do: Progress.accept_file_change(update, session, @workspace, seen)

  defp update(opts \\ []) do
    %{
      event: :notification,
      payload: %{
        "method" => Keyword.get(opts, :method, "item/completed"),
        "params" => %{
          "threadId" => Keyword.get(opts, :thread, "thread"),
          "turnId" => Keyword.get(opts, :turn, "turn"),
          "item" => %{
            "type" => Keyword.get(opts, :type, "fileChange"),
            "status" => Keyword.get(opts, :status, "completed"),
            "id" => Keyword.get(opts, :id, "exec-id"),
            "changes" => Keyword.get(opts, :changes, [change(opts)])
          }
        }
      }
    }
  end

  defp change(opts \\ []) do
    %{
      "path" => Keyword.get(opts, :path, @workspace <> "/file"),
      "kind" => Keyword.get(opts, :kind, %{"type" => "add"}),
      "diff" => Keyword.get(opts, :diff, "+actual change")
    }
  end
end
