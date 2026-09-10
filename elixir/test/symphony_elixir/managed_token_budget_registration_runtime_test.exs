defmodule SymphonyElixir.ManagedTokenBudgetRegistrationRuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ManagedTokenBudget, as: Budget
  alias SymphonyElixir.ManagedTokenBudget.Runtime

  test "registered issue requires a current matching grant before runtime admission" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", codex_max_total_tokens: 500_000)
    journal = Path.join(Path.dirname(Workflow.workflow_file_path()), "registration-claim.json")
    path = journal <> ".token-usage.jsonl"
    identity = %{pool_key: "pool", repository_ref: "owner/repo", managed_project_profile_id: "profile"}
    issue = "c2222222-2222-4222-8222-222222222222"
    {:ok, ledger} = Budget.initialize(path, identity, [])

    attrs = %{
      issue_id: issue,
      known_minimum_tokens: 0,
      continuation_floor: 1,
      evidence_ref: "evidence:new",
      authority_ref: "authority:new",
      ledger_prefix_sha256: Base.encode16(ledger.file_hash, case: :lower),
      ledger_prefix_size_bytes: ledger.file_size
    }

    assert {:ok, _} = Budget.register_new_issue(ledger, attrs)
    assert {:ok, registered} = Budget.load(path, identity)
    grant = %{issue_id: issue, responsible: %{budget: %{max_tokens: 500_000}}}
    runtime = %{journal_path: journal, managed_project_profile_id: "profile", managed_delegations: Map.put(identity, :entries, [grant])}
    state = %{work_package_runtime: runtime, managed_token_budget: registered, managed_token_budget_error: nil}
    assert :ok = Runtime.admission(state, issue)
    without_grant = put_in(runtime, [:managed_delegations, :entries], [])
    assert {:error, _} = Runtime.admission(%{state | work_package_runtime: without_grant}, issue)
    nil_grant = %{grant | responsible: %{budget: nil}}
    nil_runtime = put_in(runtime, [:managed_delegations, :entries], [nil_grant])
    assert {:error, _} = Runtime.admission(%{state | work_package_runtime: nil_runtime}, issue)
    wrong_path = %{runtime | journal_path: journal <> ".other"}
    assert {:error, _} = Runtime.admission(%{state | work_package_runtime: wrong_path}, issue)
    assert :ok = Runtime.admission(state, issue)
  end
end
