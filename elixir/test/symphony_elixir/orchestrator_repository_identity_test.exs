defmodule SymphonyElixir.OrchestratorRepositoryIdentityTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Orchestrator

  setup do
    previous_pool_key = System.get_env("SYMPHONY_POOL_KEY")
    previous_repository_ref = System.get_env("SYMPHONY_REPOSITORY_REF")

    on_exit(fn ->
      restore_env("SYMPHONY_POOL_KEY", previous_pool_key)
      restore_env("SYMPHONY_REPOSITORY_REF", previous_repository_ref)
    end)

    :ok
  end

  test "uses the validated pool repository reference" do
    System.put_env("SYMPHONY_POOL_KEY", "midgard")
    System.put_env("SYMPHONY_REPOSITORY_REF", "hypergridau/midgard")

    assert Orchestrator.repository_identity() == "hypergridau/midgard"
  end

  test "keeps the upstream identity outside a repository pool" do
    System.delete_env("SYMPHONY_POOL_KEY")
    System.delete_env("SYMPHONY_REPOSITORY_REF")

    assert Orchestrator.repository_identity() == "openai/symphony"
  end

  test "fails closed when the pool identity is incomplete" do
    System.put_env("SYMPHONY_POOL_KEY", "midgard")
    System.delete_env("SYMPHONY_REPOSITORY_REF")

    assert_raise ArgumentError, ~r/requires both pool and repository/, fn ->
      Orchestrator.repository_identity()
    end
  end

  test "fails closed when the repository reference is malformed" do
    System.put_env("SYMPHONY_POOL_KEY", "midgard")
    System.put_env("SYMPHONY_REPOSITORY_REF", "C:/arbitrary/worktree")

    assert_raise ArgumentError, ~r/invalid Symphony pool repository reference/, fn ->
      Orchestrator.repository_identity()
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
