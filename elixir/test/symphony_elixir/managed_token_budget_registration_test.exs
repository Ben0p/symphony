defmodule SymphonyElixir.ManagedTokenBudgetRegistrationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ManagedTokenBudget, as: Budget
  alias SymphonyElixir.ManagedTokenBudget.{Codec, Registration}

  @identity %{pool_key: "pool", repository_ref: "owner/repo", managed_project_profile_id: "profile"}
  @old "a1111111-1111-4111-8111-111111111111"
  @new "c2222222-2222-4222-8222-222222222222"

  setup do
    nonce = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    root = Path.join(System.tmp_dir!(), "budget-registration-#{nonce}")
    File.mkdir_p!(root)
    %{path: Path.join(root, "usage.jsonl")}
  end

  test "empty pool registration persists a zero baseline and seals bootstrap", %{path: path} do
    {:ok, ledger} = Budget.initialize(path, @identity, [])
    prefix = File.read!(path)
    attrs = attrs_for(ledger)
    assert {:ok, registered} = Budget.register_new_issue(ledger, attrs)
    assert binary_part(File.read!(path), 0, byte_size(prefix)) == prefix
    assert registered.phase == :usage
    assert registered.baselines[@new] == baseline(@new, 0)
    assert registered.issue_totals[@new] === 0
    assert registered.highwaters == %{}
    assert registered.threads == %{}
    assert {:ok, ^registered} = Budget.load(path, @identity)

    row = baseline(@old) |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end) |> Map.merge(%{"kind" => "bootstrap", "version" => 1})
    File.write!(path, Codec.encode(row), [:append])
    assert {:error, _} = Budget.load(path, @identity)
  end

  test "registration retains usage, replays and is idempotent after later usage", %{path: path} do
    {:ok, ledger} = Budget.initialize(path, @identity, [baseline(@old)])
    {:ok, used} = Budget.observe(ledger, @old, 1, "old-thread", 9)
    prefix = File.read!(path)
    attrs = attrs_for(used)
    assert {:ok, registered} = Budget.register_new_issue(used, attrs)
    assert binary_part(File.read!(path), 0, byte_size(prefix)) == prefix
    assert {:ok, next} = Budget.observe(registered, @new, 1, "new-thread", 5)
    assert {:ok, _} = Budget.observe(next, @old, 2, "later-thread", 3)
    assert {:ok, reloaded} = Budget.load(path, @identity)
    assert reloaded.issue_totals == %{@old => 22, @new => 5}
    assert Map.take(reloaded.highwaters, Map.keys(used.highwaters)) == used.highwaters
    assert Map.take(reloaded.threads, Map.keys(used.threads)) == used.threads
    assert reloaded.registrations[@new] == attrs
    assert reloaded.corrections == used.corrections
    before = File.read!(path)

    for key <- [:evidence_ref, :authority_ref] do
      assert {:error, :registration_conflict} = Budget.register_new_issue(reloaded, Map.put(attrs, key, "conflict"))
      assert File.read!(path) == before
    end

    assert {:ok, ^reloaded} = Budget.register_new_issue(reloaded, attrs)
    assert File.read!(path) == before
  end

  test "uppercase historical UUID cannot become a new lowercase issue", %{path: path} do
    {:ok, ledger} = Budget.initialize(path, @identity, [baseline(String.upcase(@new))])
    before = File.read!(path)
    assert {:error, :registration_issue_exists} = Budget.register_new_issue(ledger, attrs_for(ledger))
    assert File.read!(path) == before
  end

  test "all issue-bearing structures reject aliases, including correction history", %{path: path} do
    {:ok, ledger} = Budget.initialize(path, @identity, [])
    attrs = attrs_for(ledger)
    bytes = File.read!(path)
    upper = String.upcase(@new)

    variants = [
      %{ledger | issue_totals: %{upper => 0}},
      %{ledger | highwaters: %{{upper, 1, "thread"} => 0}},
      %{ledger | threads: %{{upper, 1} => "thread"}},
      %{ledger | registrations: %{upper => attrs}},
      %{ledger | corrections: %{"correction" => %{attrs: %{issue_id: upper}}}},
      %{ledger | corrections: %{"correction" => %{attrs: %{issue_id: @old}, original_baseline: baseline(upper)}}}
    ]

    for state <- variants, do: assert({:error, :registration_issue_exists} = Registration.prepare(state, attrs, bytes))
    assert {:error, _} = Registration.prepare(%{phase: :usage}, attrs, bytes)
    assert {:error, _} = Registration.prepare(%{ledger | phase: :unknown}, attrs, bytes)
  end

  test "invalid input fails closed without changing disk", %{path: path} do
    {:ok, ledger} = Budget.initialize(path, @identity, [])
    attrs = attrs_for(ledger)
    before = File.read!(path)

    changes = [
      {:known_minimum_tokens, 0.0},
      {:known_minimum_tokens, 1},
      {:continuation_floor, 1.0},
      {:continuation_floor, 2},
      {:issue_id, <<255>>},
      {:issue_id, String.upcase(@new)},
      {:issue_id, "HGS-493"},
      {:ledger_prefix_sha256, <<255>>},
      {:ledger_prefix_sha256, String.duplicate("F", 64)},
      {:ledger_prefix_size_bytes, 0},
      {:ledger_prefix_size_bytes, 1.0},
      {:evidence_ref, <<255>>},
      {:evidence_ref, ""},
      {:authority_ref, " padded "},
      {:extra, true}
    ]

    for {key, value} <- changes do
      assert {:error, _} = Budget.register_new_issue(ledger, Map.put(attrs, key, value))
      assert File.read!(path) == before
    end

    assert {:error, _} = Budget.register_new_issue(ledger, Map.delete(attrs, :authority_ref))
    assert {:error, _} = Budget.register_new_issue(ledger, nil)
    assert {:error, _} = Budget.register_new_issue(path, attrs)
  end

  test "physical duplicate, wrong row version, size and digest reject replay", %{path: path} do
    variants = [:duplicate, :version, :size, :hash]

    for variant <- variants do
      file = path <> Atom.to_string(variant)
      {:ok, ledger} = Budget.initialize(file, @identity, [])
      attrs = attrs_for(ledger)
      assert {:ok, _} = Budget.register_new_issue(ledger, attrs)
      bytes = File.read!(file)
      [header, record] = String.split(bytes, "\n", trim: true)
      row = Jason.decode!(record)

      invalid =
        case variant do
          :duplicate -> bytes <> record <> "\n"
          :version -> header <> "\n" <> Codec.encode(Map.put(row, "version", 1.0))
          :size -> header <> "\n" <> Codec.encode(Map.update!(row, "ledger_prefix_size_bytes", &(&1 + 1)))
          :hash -> header <> "\n" <> Codec.encode(Map.put(row, "ledger_prefix_sha256", different_hash(attrs.ledger_prefix_sha256)))
        end

      File.write!(file, invalid)
      assert {:error, _} = Budget.load(file, @identity)
    end
  end

  test "valid historical JSON mutation and inserted rows cannot retain registration", %{path: path} do
    for variant <- [:mutation, :insertion] do
      file = path <> Atom.to_string(variant)
      {:ok, ledger} = Budget.initialize(file, @identity, [baseline(@old)])
      assert {:ok, _} = Budget.register_new_issue(ledger, attrs_for(ledger))
      [header, baseline_row, registration] = String.split(File.read!(file), "\n", trim: true)
      historical = Jason.decode!(baseline_row)

      modified =
        case variant do
          :mutation -> Codec.encode(Map.put(historical, "known_minimum_tokens", 11))
          :insertion -> baseline_row <> "\n" <> Codec.encode(Map.put(historical, "issue_id", "b3333333-3333-4333-8333-333333333333"))
        end

      File.write!(file, header <> "\n" <> modified <> registration <> "\n")
      assert {:error, _} = Budget.load(file, @identity)
    end
  end

  test "stale loaded ledger cannot append registration", %{path: path} do
    {:ok, ledger} = Budget.initialize(path, @identity, [baseline(@old)])
    {:ok, _used} = Budget.observe(ledger, @old, 1, "old-thread", 2)
    before = File.read!(path)
    assert {:error, _} = Budget.register_new_issue(ledger, attrs_for(ledger))
    assert File.read!(path) == before
  end

  test "pending and blocked markers are retained and prevent registration", %{path: path} do
    for suffix <- [".pending", ".blocked"] do
      file = path <> suffix <> ".ledger"
      {:ok, ledger} = Budget.initialize(file, @identity, [])
      before = File.read!(file)
      File.write!(file <> suffix, "hold")
      assert {:error, _} = Budget.register_new_issue(ledger, attrs_for(ledger))
      assert File.read!(file) == before
      assert File.read!(file <> suffix) == "hold"
      assert {:error, _} = Budget.load(file, @identity)
    end
  end

  test "registration preserves the twenty-issue cap", %{path: path} do
    ids = Enum.map(1..20, &("b1111111-1111-4111-8111-" <> String.pad_leading(Integer.to_string(&1), 12, "0")))
    {:ok, ledger} = Budget.initialize(path, @identity, Enum.map(ids, &baseline/1))
    before = File.read!(path)
    assert {:error, :registration_limit} = Budget.register_new_issue(ledger, attrs_for(ledger))
    assert File.read!(path) == before
  end

  test "nineteen legacy baselines allow a twentieth registration but never a twenty-first", %{path: path} do
    ids = Enum.map(1..19, &("b1111111-1111-4111-8111-" <> String.pad_leading(Integer.to_string(&1), 12, "0")))
    {:ok, ledger} = Budget.initialize(path, @identity, Enum.map(ids, &baseline/1))
    assert ledger.phase == :bootstrap
    assert ledger.registrations == %{}
    assert {:ok, registered} = Budget.register_new_issue(ledger, attrs_for(ledger))
    assert map_size(registered.baselines) == 20
    assert registered.phase == :usage
    before = File.read!(path)
    attrs = %{attrs_for(registered) | issue_id: "d4444444-4444-4444-8444-444444444444"}
    assert {:error, :registration_limit} = Budget.register_new_issue(registered, attrs)
    assert File.read!(path) == before
    assert {:ok, ^registered} = Budget.load(path, @identity)
  end

  defp baseline(id, minimum \\ 10) do
    %{
      issue_id: id,
      known_minimum_tokens: minimum,
      continuation_floor: 1,
      evidence_ref: "evidence:" <> id,
      authority_ref: "authority:" <> id
    }
  end

  defp attrs_for(ledger) do
    Map.merge(baseline(@new, 0), %{
      ledger_prefix_sha256: Base.encode16(ledger.file_hash, case: :lower),
      ledger_prefix_size_bytes: ledger.file_size
    })
  end

  defp different_hash("0" <> rest), do: "1" <> rest
  defp different_hash(<<_first, rest::binary>>), do: "0" <> rest
end
