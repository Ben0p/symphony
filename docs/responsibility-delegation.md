# Responsibility and delegation contract

`SymphonyElixir.ResponsibilityGraph` is the organisation-level authority layer
above the execution generation and session fence described in
`docs/execution-fencing.md`.

Each delegation names one role (`accountable`, `responsible`, `reviewer`,
`consulted`, or `observer`), a complete company/objective/initiative/project/
work-package/issue scope, bounded repository/path/environment/action authority,
a model/effort/token/child budget, an expected deliverable and evidence return
contract, and an expiry. There may be only one active accountable delegation
for an exact scope. Active responsible delegations may run in parallel only
when their scopes are deterministically disjoint.

Child delegations inherit and narrow their parent scope, capabilities,
environments, model, effort, token budget, and child budget. A parent
responsible delegation loses mutation authority over an overlapping child
scope while that child is active. Reviewers are read-only; a finding is a
proposal that a manager accepts through a new remediation delegation.

The `runtime_lease` field is a reference to an HGS-294 issue-execution lease,
not another process registry. Mutable authorization uses
`ResponsibilityGraph.authorize_with_execution_fence/4`, which requires both
the graph capability and the current generation's active worker lease. Revoking
or terminalizing a delegation returns the affected lease references and
`revoke_and_fence/6` fences those generations through HGS-294 before the caller
performs cleanup.

The orchestrator persists the graph as a versioned, sanitized JSON snapshot at
`responsibility-graph.json` beside the execution-fence snapshot. On restart,
active delegations are blocked until their runtime lease is explicitly
reconciled. The orchestrator exposes only a read-only graph projection for
operations surfaces; delegation mutations remain explicit API calls with
typed validation.
