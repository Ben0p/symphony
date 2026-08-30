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

The graph starts in `manual` mode while the bootstrap is still coordinated by
the bounded prompt convention. After the graph has been reviewed and proven,
the orchestrator can persist `enforced` mode through
`Orchestrator.activate_responsibility_graph/1`. In enforced mode, normal worker
admission must find exactly one active responsible delegation for the issue and
bind its HGS-294 runtime lease before the worker starts. The worker's side-effect
guard then authorizes through both contracts; an active worker exit releases the
binding so a bounded retry can receive a fresh generation.

The orchestrator persists the graph as a versioned, sanitized JSON snapshot at
`responsibility-graph.json` beside the execution-fence snapshot. On restart,
delegations already bound to a runtime lease are blocked until that lease is
explicitly reconciled. Unbound responsible delegations remain active because
no worker has owned them yet; first admission binds their fresh HGS-294
generation. The orchestrator exposes only a read-only graph projection for
operations surfaces; delegation mutations remain explicit API calls with
typed validation.
