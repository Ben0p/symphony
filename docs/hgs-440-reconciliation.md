# HGS-440 fork reconciliation record

This branch reconciles the owned Ben0p/symphony default branch
`04d7955ed256832c28fd235af7d031d45c5e98aa` with the accepted runtime source
`44d87540d34762ba8533ae09f65a49e271de2d03`. The merge base is
`8001b52e3062495a16e520e4ceaf8f9de868c4d0`. The source merge is intentionally
reviewable: both parent histories remain visible in the resulting merge commit.

The fork's HGS-300 behavior was checked before resolving conflicts. The
responsibility graph and persistence modules are endpoint-identical after the
fork's restart-admission fix; the accepted runtime also contains the bootstrap,
admission, runtime-lease, restart-reconciliation, and test coverage. The
accepted endpoint therefore preserves that behavior while retaining the later
HGS-349 fencing, supervisor, cleanup, pause, readiness, and locking behavior.

## Conflict decisions

Each conflict was compared at both endpoints. The accepted-runtime endpoint was
selected only where the fork endpoint removed or predates behavior that is still
required by the active runtime. The selected files were not resolved by a
repository-wide preference rule.

| Path | Decision and evidence |
| --- | --- |
| `docs/responsibility-delegation.md` | Accepted endpoint: documents the current activation, admission, restart, and lease semantics present in the accepted graph implementation. |
| `elixir/lib/symphony_elixir.ex` | Accepted endpoint: retains `RunnerObservationReporter` supervision required by the accepted runtime. |
| `elixir/lib/symphony_elixir/agent_runner.ex` | Accepted endpoint: retains execution-supervisor and secret-environment plumbing around the fork's worker admission path. |
| `elixir/lib/symphony_elixir/codex/app_server.ex` | Accepted endpoint: retains supervisor identity recording, cleanup on startup failure, shell selection, secret scrubbing, and the HGS-188 app-server/SSH behavior. |
| `elixir/lib/symphony_elixir/config/schema.ex` | Accepted endpoint: retains the current stall and total-budget configuration contract used by the accepted orchestrator. |
| `elixir/lib/symphony_elixir/execution_fence.ex` | Accepted endpoint: retains generation leases, supervisor identity, termination evidence, cleanup receipts, and terminal fencing. |
| `elixir/lib/symphony_elixir/execution_fence/persistence.ex` | Accepted endpoint: retains durable encoding/decoding for worker host, cleanup receipt, termination, and supervisor evidence. |
| `elixir/lib/symphony_elixir/orchestrator.ex` | Accepted endpoint: retains responsibility admission plus later pause, supervisor, cleanup-replay, readiness, locking, and crash-release paths. |
| `elixir/lib/symphony_elixir/ssh.ex` | Accepted endpoint: retains the accepted Windows/Linux SSH shim contract; HGS-188 is already represented by current tests. |
| `elixir/lib/symphony_elixir/workspace.ex` | Accepted endpoint: retains bounded remote cleanup, cleanup receipts, path checks, and the HGS-434 reparse-safe local cleanup contract. |
| `elixir/lib/symphony_elixir_web/presenter.ex` | Accepted endpoint: retains managed runtime identity, execution authority, readiness, and pause state in the read model. |
| `elixir/mix.lock` | Accepted endpoint: keeps the dependency lock used by the accepted source and its current validation toolchain. |
| `elixir/test/mix/tasks/workspace_before_remove_test.exs` | Accepted endpoint: keeps the current cleanup task assertions, including the HGS-434 contract. |
| `elixir/test/support/test_support.exs` | Accepted endpoint: keeps the accepted fixture helpers needed by supervision, cleanup, and admission tests. |
| `elixir/test/symphony_elixir/app_server_test.exs` | Accepted endpoint: keeps app-server startup, supervisor, secret-scrubbing, and sandbox assertions. |
| `elixir/test/symphony_elixir/core_test.exs` | Accepted endpoint: keeps the accepted application supervision and startup contract. |
| `elixir/test/symphony_elixir/execution_fence_persistence_test.exs` | Accepted endpoint: keeps persistence coverage for cleanup receipts, termination evidence, and legacy state recovery. |
| `elixir/test/symphony_elixir/execution_fence_test.exs` | Accepted endpoint: keeps generation, lease, supervisor, termination, and terminal-fence coverage. |
| `elixir/test/symphony_elixir/extensions_test.exs` | Accepted endpoint: keeps the current dashboard/API projections for pause, readiness, identity, and authority. |
| `elixir/test/symphony_elixir/orchestrator_execution_fence_test.exs` | Accepted endpoint: keeps integration coverage for responsibility admission together with fencing, cleanup, retry, and crash recovery. |
| `elixir/test/symphony_elixir/orchestrator_status_test.exs` | Accepted endpoint: keeps status transitions and bounded retry/reconciliation assertions from the accepted runtime. |
| `elixir/test/symphony_elixir/workspace_and_config_test.exs` | Accepted endpoint: keeps current workspace containment, remote cleanup, and configuration validation coverage. |

The non-conflicting fork HGS-300 modules and tests remain in the merged tree.
In particular, `ResponsibilityGraph`, `ResponsibilityGraph.Persistence`,
`ResponsibilityBootstrap`, `WorkPackageClaim`, and their tests are present;
`elixir/lib/symphony_elixir/cli.ex` still exposes the opt-in
`--activate-responsibility-graph` switch. No runtime activation or delivery pin
change is part of this source reconciliation.

## Verification scope

The candidate must be qualified with the local Elixir 1.19.5 / OTP 28.5
toolchain from `mise.toml` on both Windows and Linux. The Windows executable
paths are `C:\Users\skitt\AppData\Local\mise\installs\elixir\1.19.5-otp-28\bin`
and `C:\Users\skitt\AppData\Local\mise\installs\erlang\28.5\bin`.
Toolchain availability and Docker-based isolated fixtures are reported with
the test evidence; no customer or PostgreSQL fixture is used by this source
qualification.

## Cross-platform qualification repairs

The 2026-09-08 qualification retains all production code from the accepted
runtime. Explicit LF attributes prevent Windows checkout/archive settings from
converting embedded Unix shell fixtures to CRLF. The committed source blobs
already used LF; this fixes delivery of those bytes to the Linux test host.

Two Linear transport tests now assert the existing fail-closed lock error and
absence of a transport call on hosts without the supported Unix `flock` path.
Their original response, logging, and bound-settings assertions still run on
Linux. The restart-fencing fixture uses a bounded release-marker loop instead
of an unbounded FIFO read, so aborting a test cannot leave its shell waiting
indefinitely. The production lock and execution fences are unchanged.

Original automatic denials and failed qualification logs are retained in the
HGS-440 evidence linked from Linear. A fresh test request with durable output
and no evidence deletion was admitted through the same execution review path.
Source validation, fork merge, runtime installation, and managed acceptance
remain distinct milestones.
