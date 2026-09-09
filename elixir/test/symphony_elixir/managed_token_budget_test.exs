defmodule SymphonyElixir.ManagedTokenBudgetTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.ManagedTokenBudget, as: Budget

  @identity %{pool_key: "pool", repository_ref: "hypergrid/repo", managed_project_profile_id: "profile"}
  @a "11111111-1111-4111-8111-111111111111"
  @b "22222222-2222-4222-8222-222222222222"
  @provenance %{evidence_ref: "test:retained-usage", authority_ref: "test:reviewed-bootstrap"}
  @baseline Map.merge(@provenance, %{issue_id: @a, known_minimum_tokens: 1_048_273, continuation_floor: 22})

  setup do
    unique = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    dir = Path.join(System.tmp_dir!(), "managed-budget-#{unique}")
    File.mkdir!(dir)
    %{dir: dir, path: Path.join(dir, "usage.jsonl")}
  end

  test "multiple issue totals survive restart, including known overshoot", %{path: path} do
    second = %{@baseline | issue_id: @b, known_minimum_tokens: 19, continuation_floor: 1}
    {:ok, ledger} = Budget.initialize(path, @identity, [@baseline, second])
    ledger = observe(ledger, @a, 22, "thread-a", 273)
    ledger = observe(ledger, @b, 1, "thread-b", 6)
    {:ok, restored} = Budget.load(path, @identity)
    assert restored.issue_totals == %{@a => 1_048_546, @b => 25}
    assert restored.issue_totals == ledger.issue_totals
    assert Budget.verify(restored) == :ok
  end

  test "equal and lower cumulative observations preserve the highwater without appending", %{path: path} do
    ledger = initialize(path) |> observe(@a, 22, "thread", 50)
    before = File.read!(path)
    ledger = ledger |> observe(@a, 22, "thread", 10) |> observe(@a, 22, "thread", 50)
    assert File.read!(path) == before
    ledger = observe(ledger, @a, 22, "thread", 65)
    assert ledger.issue_totals[@a] == 1_048_338
    assert ledger.highwaters[{@a, 22, "thread"}] == 65
  end

  test "first zero binds one actual thread and later generations add new-thread consumption", %{path: path} do
    ledger = initialize(path) |> observe(@a, 22, "thread-a", 0)
    assert ledger.highwaters[{@a, 22, "thread-a"}] == 0
    assert {:error, _} = Budget.observe(ledger, @a, 22, "thread-b", 1)
    assert {:error, _} = Budget.observe(ledger, @a, 23, "thread-a", 1)
    next = observe(ledger, @a, 23, "thread-b", 7)
    assert next.issue_totals[@a] == 1_048_280
  end

  test "below-floor and unknown issues fail both live and during replay", %{path: path} do
    ledger = initialize(path)
    before = File.read!(path)
    assert {:error, _} = Budget.observe(ledger, @a, 21, "thread", 0)
    assert {:error, _} = Budget.observe(ledger, @b, 22, "thread", 0)
    assert File.read!(path) == before
    File.write!(path, before <> row("usage", %{issue_id: @a, generation: 21, thread_id: "thread", cumulative_total_tokens: 0}))
    assert {:error, _} = Budget.load(path, @identity)
  end

  test "bootstrap is explicit, bounded, unique and exclusive", %{path: path} do
    for baselines <- [[@baseline, @baseline], List.duplicate(@baseline, 21), [nil]] do
      assert {:error, _} = Budget.initialize(path, @identity, baselines)
    end

    File.write!(path, "retained")
    assert {:error, _} = Budget.initialize(path, @identity, [@baseline])
    assert File.read!(path) == "retained"
  end

  test "an empty pool has no implicitly authorized issue", %{path: path} do
    assert {:ok, ledger} = Budget.initialize(path, @identity, [])
    assert ledger.issue_totals == %{}
    assert {:error, _} = Budget.observe(ledger, @a, 1, "thread", 0)
  end

  test "missing, partial, noncanonical, duplicate-key and unknown rows fail closed", %{path: path} do
    assert {:error, _} = Budget.load(path, @identity)
    initialize(path)
    original = File.read!(path)

    invalid = [
      String.trim_trailing(original),
      original <> "{broken}\n",
      original <> "\n",
      String.replace(original, "\"version\":1", "\"version\":1,\"version\":1"),
      original <> row("unknown", %{}),
      String.replace(original, "\"pool\"", "\"other\""),
      String.replace(original, ":1", ": 1")
    ]

    for bytes <- invalid do
      File.write!(path, bytes)
      assert {:error, _} = Budget.load(path, @identity)
    end
  end

  test "duplicate and late baseline records fail replay", %{path: path} do
    initialize(path)
    before = File.read!(path)
    File.write!(path, before <> row("bootstrap", @baseline))
    assert {:error, _} = Budget.load(path, @identity)
    usage = row("usage", %{issue_id: @a, generation: 22, thread_id: "thread", cumulative_total_tokens: 1})
    File.write!(path, before <> usage <> row("bootstrap", %{@baseline | issue_id: @b}))
    assert {:error, _} = Budget.load(path, @identity)
  end

  test "relative, absent-parent, and linked paths cannot initialize", %{dir: dir} do
    assert {:error, _} = Budget.initialize("relative.jsonl", @identity, [@baseline])
    assert {:error, _} = Budget.initialize(Path.join(dir, "missing/usage.jsonl"), @identity, [@baseline])
    real = Path.join(dir, "real")
    File.mkdir!(real)
    link = Path.join(dir, "link")
    :ok = File.ln_s(real, link)
    assert {:error, _} = Budget.initialize(Path.join(link, "usage.jsonl"), @identity, [@baseline])
    :ok = File.ln_s(Path.join(dir, "missing"), Path.join(real, "usage.jsonl"))
    assert {:error, _} = Budget.load(Path.join(real, "usage.jsonl"), @identity)
  end

  test "external changes invalidate even zero or equal observations", %{path: path} do
    ledger = initialize(path) |> observe(@a, 22, "thread", 30)
    File.write!(path, String.replace(File.read!(path), "test:retained-usage", "test:modified-usage"))
    assert {:error, _} = Budget.verify(ledger)

    for total <- [0, 10, 30, 31] do
      assert {:error, _} = Budget.observe(ledger, @a, 22, "thread", total)
    end
  end

  test "pending append and durable block survive restart without repair", %{path: path} do
    ledger = initialize(path)
    pending = path <> ".pending"
    File.write!(pending, "uncertain-append")
    assert {:error, _} = Budget.verify(ledger)
    assert {:error, _} = Budget.load(path, @identity)
    assert File.read!(pending) == "uncertain-append"
    assert :ok = Budget.block(ledger)
    assert File.read!(path <> ".blocked") == "managed_usage_requires_reconciliation\n"
    assert {:error, _} = Budget.load(path, @identity)
  end

  test "an orphan pending intent prevents initialization", %{path: path} do
    File.write!(path <> ".pending", "retained")
    assert {:error, _} = Budget.initialize(path, @identity, [@baseline])
    assert {:error, :enoent} = File.lstat(path)
  end

  @tag skip: System.cmd("id", ["-u"]) == {"0\n", 0}
  test "an actual append permission failure retains its intent and blocks restart", %{path: path} do
    ledger = initialize(path)
    File.chmod!(path, 0o400)
    assert {:error, :budget_write_pending_reconciliation} = Budget.observe(ledger, @a, 22, "thread", 50)
    assert File.regular?(path <> ".pending")
    assert ledger.issue_totals[@a] == 1_048_273
    assert {:error, _} = Budget.load(path, @identity)
  end

  defp initialize(path) do
    {:ok, ledger} = Budget.initialize(path, @identity, [@baseline])
    ledger
  end

  defp observe(ledger, issue, generation, thread, cumulative) do
    {:ok, next} = Budget.observe(ledger, issue, generation, thread, cumulative)
    next
  end

  defp row(kind, attrs) do
    attrs |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end) |> Map.merge(%{"kind" => kind, "version" => 1}) |> Jason.encode!() |> Kernel.<>("\n")
  end
end
