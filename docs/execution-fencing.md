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
  unquiescent, or has unknown/contradictory ownership. Terminal tracker state
  dominates stale non-terminal session observations.

`reconcile_sessions/4` consumes an explicit, sanitized session snapshot. It
returns deterministic `:reconciled` or `:blocked` evidence and expires leases
whose last heartbeat exceeds the caller-supplied TTL. Unknown sessions,
scope/head/process contradictions, future heartbeats, and stale terminal
observations remain fail-closed.

The current orchestrator can adopt this contract at its scheduling and
workspace boundaries without giving the contract authority to delete a
worktree, mutate a branch, terminate a process, or change Linear/GitHub state.
