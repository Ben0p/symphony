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

  defp executable(ctx, body) do
    File.write!(ctx.executable, "#!/bin/bash\n" <> body <> "\n")
    File.chmod!(ctx.executable, 0o755)
  end
end
