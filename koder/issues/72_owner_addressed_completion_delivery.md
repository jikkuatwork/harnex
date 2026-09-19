---
status: open
priority: P1
created: 2026-09-19
updated: 2026-09-19
tags: pi, notifications, lifecycle
type: bug
issue_kind: slice
---

# Issue 72 — Address completion delivery to the dispatch's primary session

Repository-wide shell wake files let a worker or unrelated session consume a
primary's completion. The native marker is durable but is neither addressed nor
retained across reuse of the same dispatch name. Capture the existing external
primary identity (`--orchestration-session-id`, defaulting to Pi's shell-tool
`PI_SESSION_ID`) before crossing tmux, and maintain a per-owner, per-attempt
notification record. Register it before the initial prompt so a consumer can
attach a native bounded watcher; settle it independently of the optional hook.

## Bounds and acceptance

- Scope: runner identity propagation, notification registration/settlement,
  matching tests and operator guidance. No scheduler, queue, or #71 deadline redesign.
- Wrong owners cannot be confused through tmux environment inheritance.
- Dispatch-name reuse does not erase unacknowledged attempt records.
- Registration failure is loud and fails before the initial prompt; terminal
  write failure leaves the registered record available for native-watch recovery.
- Keep the original typed markers and optional hook contract intact.
- Consumer-side acknowledgment/role exclusion is validated by the consuming
  extension, not certified merely by the presence of a native marker.
- Gate: focused regressions, full Ruby suite, then installed-CLI local smoke.

Source exposure: none — implementation and synthetic proofs stay local; no
repository content, private incident logs, package, or Git objects are published.
