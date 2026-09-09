defmodule SymphonyElixir.ManagedTokenBudgetCorrectionTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.ManagedTokenBudget, as: Budget
  alias SymphonyElixir.ManagedTokenBudget.Runtime

  @identity %{pool_key: "pool", repository_ref: "hypergrid/repo", managed_project_profile_id: "profile"}
  @a "11111111-1111-4111-8111-111111111111"
  @b "22222222-2222-4222-8222-222222222222"
  @c "33333333-3333-4333-8333-333333333333"
  @baseline %{issue_id: @a, known_minimum_tokens: 0, continuation_floor: 20, evidence_ref: "test:historical-bootstrap", authority_ref: "test:original-authority"}

  setup do
    unique = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    dir = Path.join(System.tmp_dir!(), "managed-floor-correction-#{unique}")
    File.mkdir!(dir)
    %{dir: dir, path: Path.join(dir, "usage.jsonl")}
  end

  test "appends without altering historical bytes and admits the real first issue generation", %{path: path} do
    second = %{@baseline | issue_id: @b, known_minimum_tokens: 256_518}
    {:ok, original} = Budget.initialize(path, @identity, [@baseline, second])
    before = File.read!(path)
    token = %{issue_id: @a, generation: 1}
    state = %{managed_token_budget: original}
    assert {:error, :managed_budget_generation_before_floor} = Runtime.generation(state, token)
    assert {:error, _} = Budget.observe(original, @a, 1, "thread-a", 0)
    attrs = attrs(path)
    {:ok, corrected} = Budget.correct_unstarted_floor(original, attrs)
    after_bytes = File.read!(path)
    assert binary_part(after_bytes, 0, byte_size(before)) == before
    assert length(String.split(after_bytes, "\n")) == length(String.split(before, "\n")) + 1
    assert corrected.corrections[attrs.correction_id].original_baseline == @baseline
    assert corrected.issue_totals == original.issue_totals
    assert corrected.baselines[@b] == second
    assert corrected.baselines[@a] == %{@baseline | continuation_floor: 1}
    {:ok, reloaded} = Budget.load(path, @identity)
    assert reloaded == corrected
    assert :ok = Runtime.generation(%{managed_token_budget: reloaded}, token)
    assert {:error, _} = Runtime.generation(%{managed_token_budget: reloaded}, %{issue_id: @b, generation: 19})
    {:ok, used} = Budget.observe(reloaded, @a, 1, "thread-a", 9)
    {:ok, used} = Budget.observe(used, @b, 20, "thread-b", 12)
    {:ok, restarted} = Budget.load(path, @identity)
    assert restarted == used
    assert restarted.issue_totals == %{@a => 9, @b => 256_530}
  end

  test "exact retries survive reload and unrelated usage without appending", %{path: path} do
    {:ok, ledger} = Budget.initialize(path, @identity, [@baseline, %{@baseline | issue_id: @b}])
    attrs = attrs(path)
    {:ok, corrected} = Budget.correct_unstarted_floor(ledger, attrs)
    before = File.read!(path)
    assert {:ok, ^corrected} = Budget.correct_unstarted_floor(corrected, attrs)
    assert File.read!(path) == before
    {:ok, used} = Budget.observe(corrected, @b, 20, "thread-b", 12)
    {:ok, reloaded} = Budget.load(path, @identity)
    before_retry = File.read!(path)
    assert {:ok, ^used} = Budget.correct_unstarted_floor(reloaded, attrs)
    assert File.read!(path) == before_retry
    assert {:error, _} = Budget.correct_unstarted_floor(reloaded, %{attrs | authority_ref: "test:different"})
    assert {:error, _} = Budget.correct_unstarted_floor(reloaded, %{attrs(path) | correction_id: "second"})
    assert {:error, _} = Budget.correct_unstarted_floor(reloaded, %{attrs(path) | issue_id: @b})
    assert File.read!(path) == before_retry
  end

  test "zero observations, positive usage and nonzero historical minima prohibit correction", %{dir: dir} do
    for {label, minimum, observation} <- [{"baseline", 1, nil}, {"zero", 0, 0}, {"positive", 0, 1}] do
      path = Path.join(dir, label)
      {:ok, ledger} = Budget.initialize(path, @identity, [%{@baseline | known_minimum_tokens: minimum}])
      ledger = if is_nil(observation), do: ledger, else: observe(ledger, observation)
      before = File.read!(path)
      assert {:error, _} = Budget.correct_unstarted_floor(ledger, attrs(path))
      assert File.read!(path) == before
      {:ok, loaded} = Budget.load(path, @identity)
      assert {:error, _} = Budget.correct_unstarted_floor(loaded, attrs(path))
    end
  end

  test "invalid authority, identity, preimage and floor fail without changing the ledger", %{path: path} do
    {:ok, ledger} = Budget.initialize(path, @identity, [@baseline])
    original = attrs(path)

    invalid = [
      nil,
      Map.delete(original, :authority_ref),
      Map.put(original, :extra, true),
      %{original | issue_id: @c},
      %{original | issue_id: "HGS-393"},
      %{original | previous_floor: 1},
      %{original | previous_floor: 21},
      %{original | new_floor: 2},
      %{original | new_floor: 1.0},
      %{original | correction_id: ""},
      %{original | correction_id: String.duplicate("x", 257)},
      %{original | ledger_before_sha256: String.duplicate("0", 64)},
      %{original | ledger_before_sha256: String.duplicate("A", 64)},
      %{original | ledger_before_sha256: :binary.copy(<<255>>, 64)},
      %{original | evidence_ref: " padded"},
      %{original | evidence_ref: <<255>>},
      %{original | authority_ref: ""},
      %{original | authority_ref: String.duplicate("x", 1025)}
    ]

    before = File.read!(path)
    for attrs <- invalid, do: assert({:error, _} = Budget.correct_unstarted_floor(ledger, attrs))
    assert File.read!(path) == before
    assert {:error, :enoent} = File.lstat(path <> ".pending")
  end

  test "replay verifies the actual historical prefix and strict correction records", %{path: path} do
    {:ok, ledger} = Budget.initialize(path, @identity, [@baseline])
    before = File.read!(path)
    attrs = attrs(path)
    {:ok, _corrected} = Budget.correct_unstarted_floor(ledger, attrs)
    after_bytes = File.read!(path)
    row = correction_row(attrs)
    bad_rows = [Map.put(row, "version", 2), Map.put(row, "extra", true), Map.delete(row, "authority_ref"), Map.put(row, "new_floor", 2), Map.put(row, "issue_id", @c)]

    bad_ledgers =
      Enum.map(bad_rows, &(before <> Jason.encode!(&1) <> "\n")) ++
        [
          String.replace(after_bytes, "test:historical-bootstrap", "test:tampered-bootstrap"),
          after_bytes <> Jason.encode!(Map.put(row, "ledger_before_sha256", hash(after_bytes))) <> "\n",
          after_bytes <> bootstrap_row(%{@baseline | issue_id: @b}),
          String.replace(after_bytes, "\"new_floor\":1", "\"new_floor\":1,\"new_floor\":1")
        ]

    for bytes <- bad_ledgers do
      File.write!(path, bytes)
      assert {:error, _} = Budget.load(path, @identity)
    end
  end

  test "stale snapshots and pending or blocked markers cannot append or retry", %{dir: dir} do
    for marker <- ["pending", "blocked", "changed", "missing"] do
      path = Path.join(dir, marker)
      {:ok, ledger} = Budget.initialize(path, @identity, [@baseline])
      attrs = attrs(path)
      {:ok, corrected} = Budget.correct_unstarted_floor(ledger, attrs)

      case marker do
        "pending" -> File.write!(path <> ".pending", "uncertain")
        "blocked" -> File.write!(path <> ".blocked", "retained")
        "changed" -> File.write!(path, File.read!(path) <> "broken\n")
        "missing" -> File.rename!(path, path <> ".retained")
      end

      assert {:error, _} = Budget.correct_unstarted_floor(corrected, attrs)
      assert {:error, _} = Budget.correct_unstarted_floor(ledger, attrs)
      assert {:error, _} = Budget.load(path, @identity)
    end
  end

  defp observe(ledger, count) do
    {:ok, next} = Budget.observe(ledger, @a, 20, "actual-thread", count)
    next
  end

  defp attrs(path) do
    %{
      issue_id: @a,
      correction_id: "test:unstarted-floor",
      previous_floor: 20,
      new_floor: 1,
      ledger_before_sha256: hash(File.read!(path)),
      evidence_ref: "test:never-started",
      authority_ref: "test:explicit-correction"
    }
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp correction_row(attrs), do: record("unstarted_floor_correction", attrs)
  defp bootstrap_row(attrs), do: record("bootstrap", attrs) |> Jason.encode!() |> Kernel.<>("\n")
  defp record(kind, attrs), do: attrs |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end) |> Map.merge(%{"kind" => kind, "version" => 1})
end
