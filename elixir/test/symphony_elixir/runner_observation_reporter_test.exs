defmodule SymphonyElixir.RunnerObservationReporterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RunnerObservationReporter

  @config %{
    url: "https://provider.example/runner/v1/symphony/observations",
    token: "opaque-bearer",
    runner_id: "runner_1",
    managed_project_profile_id: "project_1",
    pool_key: "hypergrid-gitops",
    interval_ms: 5_000,
    state_path: "/tmp/symphony-runner-observation-sequence",
    responsible_delegation_id: "delegation_1",
    execution_fence_id: "generation-1"
  }

  test "builds a sanitized active observation from the orchestrator snapshot" do
    snapshot = %{running: [%{identifier: "HGS-334"}], retrying: [], blocked: [], codex_totals: %{}}

    assert {:ok, observation} = RunnerObservationReporter.build_observation(snapshot, @config, 4, ~U[2026-09-04 10:00:00.123Z])

    assert observation == %{
             contractVersion: "symphony-runner-observation.v1",
             observationId: "runner_1:4",
             runnerId: "runner_1",
             managedProjectProfileId: "project_1",
             poolKey: "hypergrid-gitops",
             sequence: 4,
             observedAt: "2026-09-04T10:00:00.123Z",
             posture: "running",
             activeRunId: "HGS-334",
             activeRunCount: 1,
             queueDepth: 0,
             responsibleDelegationId: "delegation_1",
             executionFenceId: "generation-1"
           }
  end

  test "does not construct an active observation without responsibility and fence identity" do
    snapshot = %{running: [%{identifier: "HGS-334"}], retrying: [], blocked: []}
    assert {:error, :missing_execution_identity} = RunnerObservationReporter.build_observation(snapshot, %{@config | responsible_delegation_id: nil}, 1, DateTime.utc_now())
  end

  test "configuration is disabled when the call-home scope is incomplete" do
    assert {:disabled, :missing_configuration} = RunnerObservationReporter.configuration(%{url: nil, token: nil})
  end
end
