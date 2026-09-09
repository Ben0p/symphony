Code.require_file("../support/managed_responsibility_fixture.exs", __DIR__)

defmodule SymphonyElixir.UnsubmittedSuccessorTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{ExecutionFence, ManagedResponsibility, ResponsibilityGraph}
  alias SymphonyElixir.ManagedResponsibility.Admission
  alias SymphonyElixir.ManagedResponsibilityFixture, as: Fixture
  alias SymphonyElixir.WorkPackageClaim.{Journal, Unsubmitted}

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(workspace_root)
    options = [tracker_kind: "memory", workspace_root: workspace_root, codex_max_total_tokens: 500_000]
    write_workflow_file!(Workflow.workflow_file_path(), options)
    now = System.system_time(:millisecond)
    {:ok, graph, _} = ResponsibilityGraph.activate(ResponsibilityGraph.new(), now)
    payload = Fixture.payload(now)
    payload = update_in(payload, ["entries"], &(&1 ++ [third_entry(List.last(&1))]))
    {:ok, manifest} = ManagedResponsibility.decode(payload, Fixture.context(), now)
    runtime = %{managed_delegations: manifest, managed_project_profile_id: "profile-test", journal_path: Path.join(root, "claims.json")}
    :ok = Journal.save(runtime.journal_path, %{schema_version: 1, reservations: %{}})
    state = %Orchestrator.State{execution_fence: ExecutionFence.new(), responsibility_graph: graph, work_package_runtime: runtime}
    state = Fixture.initialize_budget(state)
    {:ok, admitted, _, _, _, _} = Orchestrator.admit_execution_for_test(state, Fixture.issue(1), nil)
    execution = admitted.execution_fence.executions[Fixture.issue(1).id]
    now = System.system_time(:millisecond)
    {:new, fence, graph} = release_unsubmitted(admitted, execution, now)
    released = %{admitted | execution_fence: fence, responsibility_graph: graph}
    :ok = ResponsibilityGraph.validate(graph)
    %{root: root, now: now, state: released, admitted: admitted, execution: fence.executions[execution.issue_id]}
  end

  test "released untouched authority admits another useful issue with unchanged prior history", context do
    before = File.read!(context.state.work_package_runtime.journal_path)
    assert {:error, :enoent} = File.lstat(context.execution.worktree)
    assert {:ok, %File.Stat{type: :directory}} = File.lstat(Path.dirname(context.execution.worktree))
    assert Path.expand(context.execution.worktree) == context.execution.worktree
    assert Unsubmitted.released_without_workspace?(context.state.work_package_runtime, context.state.execution_fence, context.state.responsibility_graph, context.execution, context.now)
    assert {:ok, next, token, _, "responsible-2", _} = Orchestrator.admit_execution_for_test(context.state, Fixture.issue(2), nil)
    assert token.issue_id == Fixture.issue(2).id
    assert next.execution_fence.executions[context.execution.issue_id] == context.execution
    assert next.execution_fence.history == context.state.execution_fence.history
    assert File.read!(context.state.work_package_runtime.journal_path) == before
    assert next.responsibility_graph.delegations["responsible-1"].runtime_lease == nil
  end

  test "six argument API remains conservative and nil manifest keeps its existing passthrough", %{state: state, now: now} do
    assert {:error, :previous_repository_cleanup_required} =
             Admission.prepare(state.responsibility_graph, state.execution_fence, state.work_package_runtime.managed_delegations, Fixture.issue(2), nil, now)

    assert {:ok, state.responsibility_graph} == Admission.prepare(state.responsibility_graph, nil, nil, nil, nil, now)
  end

  test "multiple released histories do not deadlock the repository and an active successor keeps ownership", context do
    state = context.state
    {:ok, second, _, _, _, _} = Orchestrator.admit_execution_for_test(state, Fixture.issue(2), nil)
    execution = second.execution_fence.executions[Fixture.issue(2).id]
    {:new, fence, graph} = release_unsubmitted(second, execution, System.system_time(:millisecond))
    released = %{second | execution_fence: fence, responsibility_graph: graph}
    assert {:ok, third, _, _, "responsible-3", _} = Orchestrator.admit_execution_for_test(released, Fixture.issue(3), nil)

    for id <- [Fixture.issue(1).id, Fixture.issue(2).id] do
      assert third.execution_fence.executions[id] == fence.executions[id]
    end

    assert {:error, _} = Orchestrator.admit_execution_for_test(third, Fixture.issue(1), nil)
    assert {:error, _} = Orchestrator.admit_execution_for_test(third, Fixture.issue(2), nil)
  end

  test "active lease and partial graph or fence recovery cannot use the exception", context do
    for state <- [context.admitted, %{context.state | responsibility_graph: context.admitted.responsibility_graph}, %{context.state | execution_fence: context.admitted.execution_fence}] do
      assert_blocked(state)
    end

    graph = put_in(context.state.responsibility_graph, [:delegations, "responsible-1", :parent_delegation_id], "accountable-foreign")
    assert_blocked(%{context.state | responsibility_graph: graph})
  end

  test "missing malformed unreadable or unconfigured journal never proves absence", %{state: state, root: root} do
    malformed = Path.join(root, "malformed.json")
    File.write!(malformed, "{partial")

    for path <- [Path.join(root, "missing.json"), malformed, root] do
      runtime = %{state.work_package_runtime | journal_path: path}
      assert_blocked(%{state | work_package_runtime: runtime})
    end

    # Missing configuration is distinct from a readable journal with no current row.
    assert_blocked(%{state | work_package_runtime: Map.delete(state.work_package_runtime, :managed_project_profile_id)})
  end

  test "changed old grant profile or unsupported block cannot release repository ownership", %{state: state} do
    for id <- ["responsible-1", "accountable-1"] do
      graph = put_in(state.responsibility_graph, [:delegations, id, :expected_deliverable], "Changed grant")
      assert :ok = ResponsibilityGraph.validate(graph)
      assert_blocked(%{state | responsibility_graph: graph})
    end

    runtime = %{state.work_package_runtime | managed_project_profile_id: "foreign-profile"}
    assert_blocked(%{state | work_package_runtime: runtime})
    {:ok, graph, _} = ResponsibilityGraph.block(state.responsibility_graph, "responsible-1", :review_required, System.system_time(:millisecond))
    assert_blocked(%{state | responsibility_graph: graph})
  end

  test "present file directory and dangling symlink workspaces block the next issue", context do
    path = context.execution.worktree
    File.write!(path, "retained")
    assert_blocked(context.state)
    File.rename!(path, path <> ".retained")
    File.mkdir!(path)
    assert_blocked(context.state)
    File.rename!(path, path <> ".directory")
    File.ln_s!(path <> ".missing-target", path)
    assert_blocked(context.state)
    assert File.read!(path <> ".retained") == "retained"
  end

  test "symlinked ancestor missing ancestor remote and noncanonical paths fail closed", context do
    real = Path.join(context.root, "real")
    File.mkdir!(real)
    link = Path.join(context.root, "linked")
    File.ln_s!(real, link)
    dangling = Path.join(context.root, "dangling")
    File.ln_s!(Path.join(context.root, "missing"), dangling)

    for path <- [Path.join(link, "absent"), Path.join(dangling, "absent"), Path.join(context.root, "missing/absent"), "relative/worktree", "//remote/worktree", context.root <> "/real/../absent"] do
      assert_blocked(with_execution(context.state, %{context.execution | worktree: path}))
    end

    assert_blocked(with_execution(context.state, %{context.execution | worker_host: "remote-host"}))
  end

  test "observed supervised and termination uncertain releases remain held", context do
    [session] = Map.keys(context.execution.leases)

    changes = [
      %{head: "observed"},
      %{last_heartbeat_at: 1},
      %{supervisor_identity: %{unexpected: true}},
      %{termination_required: true},
      %{release_reason: :orchestrator_stop}
    ]

    for change <- changes do
      execution = update_in(context.execution, [:leases, session], &Map.merge(&1, change))
      assert_blocked(with_execution(context.state, execution))
    end
  end

  defp with_execution(state, execution), do: put_in(state, [Access.key(:execution_fence), :executions, execution.issue_id], execution)

  defp assert_blocked(state) do
    assert {:error, _} = Orchestrator.admit_execution_for_test(state, Fixture.issue(2), nil)
  end

  defp release_unsubmitted(state, execution, now) do
    fence = state.execution_fence
    graph = state.responsibility_graph
    Unsubmitted.prepare(state.work_package_runtime, fence, graph, execution, now)
  end

  defp third_entry(entry) do
    entry = %{entry | "issue_id" => Fixture.issue(3).id, "identifier" => "HGS-3"}

    Enum.reduce(["accountable", "responsible"], entry, fn role, result ->
      update_in(result, [role], fn delegation ->
        %{
          delegation
          | "id" => role <> "-3",
            "parent_delegation_id" => if(role == "responsible", do: "accountable-3", else: nil),
            "scope" => %{delegation["scope"] | "issue_id" => Fixture.issue(3).id, "work_package_id" => "package-3"}
        }
      end)
    end)
  end
end
