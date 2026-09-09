# HGS-487 supervised startup qualification

The managed HGS-482 and HGS-483 launches on 2026-09-09 reached their worker
tasks, but immediate supervisor capture failed before the new scopes became
visible. Failure cleanup then stopped those scopes. Both attempts and their
clean workspaces remain retained; this source change does not authorize replay.

The worker now waits in the existing port-owning task for the exact live scope,
with a five-second deadline and bounded systemctl probes. It preserves incoming
port data order, observes process exit, checks the execution guard, and keeps
captured containment evidence for cleanup after subsequent failures. The
orchestrator independently captures and durably records the live identity before
Codex protocol initialization. No new worker process or admission ledger is added.

## Native evidence

Qualification used Elixir 1.19.5 / OTP 28.5 on the configured Linux runner. The
final run used the actual UID 1001 systemd user bus. Runtime pool workflows were
read directly from the six running BEAM command lines; all use approval policy
`never`. The live qualification used that existing setting.

- Targeted suite: 46 tests, zero failures, including real scope containment,
  recorder-exception cleanup, delayed visibility, early exit, pause, deadline,
  output limits, hard timeout limits, mailbox pressure, and preservation of the
  captured identity on final failure.
- Full suite: 520 tests, zero failures, 13 existing skips.
- Format, public specifications, and escript build passed.
- Coverage: 83.28%; the existing 100% threshold still fails.
- Credo: 124 findings; no added findings against the retained previous run.
- Dialyzer: 25 findings; the baseline remains unresolved.
- At 06:04:02 UTC, actual Codex completed initialize and thread/start through the
  revised AppServer after live capture and a verified persistence round trip.
  Stop, process-tree verification, and fence termination confirmation then
  completed with zero remaining processes. No model turn was requested.

`make all` remains red on baseline lint debt; it is not reported as green.
The full-suite regression and qualification fixture failures are retained with
their exact source and outputs. They include an exit-status delivery race,
missing user-bus environment, an obsolete test approval-policy value, and an
incorrect termination-confirmation fixture release reason. The latter fixtures
were corrected without changing managed runtime policy or historical evidence.

## Evidence location and remaining acceptance

Private host evidence is under
`C:/code/hypergrid-agent-archive/2026-09-08/coo-bootstrap-1315/hgs487-*`.
Guest source and numbered test rounds are retained under
`/srv/dahlia-runner-state/tmp/hgs487-native-qualification-20260909T0536/`.
The final full gates are `full-gates-v3`; actual Codex qualification is
`live-app-server-v5`. Raw evidence stays outside Git and Linear.

This is source and protocol qualification. Reviewed integration, installation,
supported reconciliation of the two attempted generations, and actual useful
managed execution remain separate acceptance steps on
[HGS-487](https://linear.app/hypergridau/issue/HGS-487) and
[HGS-351](https://linear.app/hypergridau/issue/HGS-351). Global managed pause
remains set until that recovery is ready.
