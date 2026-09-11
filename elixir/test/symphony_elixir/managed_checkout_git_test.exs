defmodule SymphonyElixir.ManagedCheckoutGitTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ManagedCheckout.Git

  setup do
    root = Path.join(System.tmp_dir!(), "checkout-git-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    original_path = System.get_env("PATH")
    System.put_env("PATH", root)

    on_exit(fn ->
      System.put_env("PATH", original_path)
      File.rm_rf!(root)
    end)

    %{root: root, executable: Path.join(root, "git")}
  end

  test "only one terminal newline is removed from successful output", ctx do
    executable(ctx, "printf ' leading and trailing \\n\\n'")
    assert {:ok, " leading and trailing \n"} = Git.run(ctx.root, ["status"])
  end

  test "over-limit output fails without returning a partial identity", ctx do
    executable(ctx, "printf '%65537s' x")
    assert {:error, reason} = Git.run(ctx.root, ["status"])

    assert reason in [
             :git_output_limit_requires_reconciliation,
             {:git_process_termination_unconfirmed, :git_output_limit_requires_reconciliation}
           ]
  end

  test "nonzero exit and missing executable are explicit errors", ctx do
    assert {:error, :git_unavailable} = Git.run(ctx.root, ["status"])
    executable(ctx, "exit 23")
    assert {:error, {:git_failed, 23}} = Git.run(ctx.root, ["status"])
  end

  @tag timeout: 25_000
  test "a silent Git process reaches the fixed deadline and preserves uncertain termination", ctx do
    # A shell builtin creates no descendant and exits when closing the port closes stdin.
    executable(ctx, "read -r -t 20 ignored")
    started = System.monotonic_time(:millisecond)
    assert {:error, reason} = Git.run(ctx.root, ["status"])
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 15_000 and elapsed < 19_000
    uncertain = {:git_process_termination_unconfirmed, :git_timeout_requires_reconciliation}
    assert reason in [:git_timeout_requires_reconciliation, uncertain]
  end

  defp executable(ctx, body) do
    File.write!(ctx.executable, "#!/bin/bash\n" <> body <> "\n")
    File.chmod!(ctx.executable, 0o755)
  end
end
