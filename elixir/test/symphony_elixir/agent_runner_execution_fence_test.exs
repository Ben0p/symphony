defmodule SymphonyElixir.AgentRunnerExecutionFenceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Tracker.Issue

  test "rejects before workspace creation when the generation is fenced" do
    test_pid = self()

    assert_raise RuntimeError, ~r/terminal_fenced/, fn ->
      AgentRunner.run(issue(), nil,
        execution_fence_guard: fn ->
          send(test_pid, :execution_fence_checked)
          {:error, :terminal_fenced}
        end
      )
    end

    assert_received :execution_fence_checked
  end

  defp issue do
    %Issue{id: "HGS-294", identifier: "HGS-294", title: "execution fence"}
  end
end
