defmodule SymphonyElixir.ManagedTokenBudgetLimitTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.ManagedTokenBudget.Limit

  @error {:error, :managed_token_budget_unavailable_or_exhausted}
  @large %{issue_id: "large", responsible: %{id: "large-grant", budget: %{max_tokens: 3_000_000}}}
  @small %{issue_id: "small", responsible: %{id: "small-grant", budget: %{max_tokens: 2_000_000}}}
  @runtime %{managed_delegations: %{entries: [@large, @small]}}

  test "heterogeneous grants remain bounded independently by the configured per-issue ceiling" do
    assert Limit.resolve(3_000_000, @runtime, "large") == {:ok, 3_000_000, @large.responsible}
    assert Limit.resolve(3_000_000, @runtime, "small") == {:ok, 2_000_000, @small.responsible}
    assert Limit.resolve(1_000_000, @runtime, "large") == {:ok, 1_000_000, @large.responsible}
  end

  test "only unmanaged zero disables the optional ceiling" do
    assert Limit.resolve(0, nil, "large") == {:ok, 0, nil}
    assert Limit.resolve(123, nil, "large") == {:ok, 123, nil}
    assert Limit.resolve(-1, nil, "large") == @error

    for invalid <- [nil, 0, -1, 1.0, "3000000"] do
      assert Limit.resolve(invalid, @runtime, "large") == @error
      assert Limit.bounded(3_000_000, %{budget: %{max_tokens: invalid}}) == @error
    end
  end

  test "missing, malformed and duplicate managed entries fail without raising" do
    for runtime <- [
          %{},
          %{managed_delegations: nil},
          %{managed_delegations: %{entries: :invalid}},
          %{managed_delegations: %{entries: []}},
          %{managed_delegations: %{entries: [@large, %{issue_id: "bad"}]}},
          %{managed_delegations: %{entries: [@large, @large]}},
          %{managed_delegations: %{entries: [@large, %{@large | issue_id: "different"}]}},
          %{managed_delegations: %{entries: [%{"issue_id" => "large"}]}},
          %{managed_delegations: %{entries: [%{issue_id: "large", responsible: nil}]}}
        ] do
      assert Limit.resolve(3_000_000, runtime, "large") == @error
    end

    assert Limit.resolve(3_000_000, @runtime, "unknown") == @error
  end
end
