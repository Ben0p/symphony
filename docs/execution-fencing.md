# Issue execution fencing

`SymphonyElixir.ExecutionFence` is the repository-local contract for safe
issue/worktree ownership across worker, reviewer, merge, and cleanup events.
It is deliberately pure: callers persist each returned snapshot atomically
and perform Git, process, tracker, or filesystem actions only after the
corresponding decision succeeds.

## Contract

- Admission creates one monotonically increasing generation for an issue. A
  mutable generation is scoped to one repository, branch, and worktree.
- A generation must explicitly register its worker and any reviewers. Each
  registration includes an opaque session/process identity, role, branch,
  worktree, tracker/PR state, head, and heartbeat.
- Every mutation guard, heartbeat, release, fence, and cleanup request carries
  the exact issue/generation token. Older generations return
  `:stale_generation` before a side effect can be considered.
- Terminal observation changes the generation to `:terminal` and records the
  terminal state, accepted head, merge identity, and observation time. It does
  not release leases implicitly; delayed workers and reviewers therefore
  remain visible until released or deterministically expired.
- Cleanup is admitted only for a terminal generation whose exact accepted head
  matches, whose ownership is reconciled, and whose leases are all released or
  expired. Repeating cleanup for that generation is `:already_cleaned`.
- A same-repository admission is blocked while another generation is active,
  unquiescent, or has unknown/contradictory ownership. Once every lease for an
  active generation is released, that generation is quiescent and the next
  admission receives a new generation, fencing the released worker token.
  Terminal tracker state dominates stale non-terminal session observations.

`reconcile_sessions/4` consumes an explicit, sanitized session snapshot. It
returns deterministic `:reconciled` or `:blocked` evidence and expires leases
whose last heartbeat exceeds the caller-supplied TTL. Unknown sessions,
scope/head/process contradictions, future heartbeats, and stale terminal
observations remain fail-closed.

The current orchestrator can adopt this contract at its scheduling and
workspace boundaries without giving the contract authority to delete a
worktree, mutate a branch, terminate a process, or change Linear/GitHub state.

The worker seam now accepts a synchronous `execution_fence_guard` callback. The
orchestrator owns the serializable snapshot, admits and registers a logical worker
lease before spawning, and the worker calls the guard before
`Workspace.create_for_issue/2`. Terminal observation fences the generation before
the existing stop path. A fenced task may therefore not begin workspace creation
or later mutable work. The current runtime does not publish an exact accepted Git
head before every terminal cleanup request; the integrated cleanup path preserves
that workspace until such a head is supplied, rather than treating `PR merged` or
an unknown head as proof of quiescence.

The orchestrator snapshot and reconciliation API expose this serializable
registry, but they do not make it restart durable. `SPEC.md` Section 14.3
continues to govern restart recovery: tracker/filesystem polling and preserved
workspaces are the recovery model. A higher-level deployment must persist and
rehydrate the serialized fence snapshot before cross-restart ownership can be
treated as durable.
