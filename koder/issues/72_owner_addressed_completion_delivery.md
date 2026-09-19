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

## Implementation checkpoint

Commit `a532a5b` implements the contract. The full suite passes `706` runs /
`3051` assertions with zero failures or errors. The exact candidate gem
(`dc55bbfd872c167fbfdb859c7591ba73b15fc259898bcf8fb573a2d6304219fe`)
was installed into an isolated local GEM home and passed end-to-end Pi smokes
for accepted completion, terminal failure, and forced terminal-delivery-write
failure recovered by a bounded native watcher. In all three, the addressed
idle consumer acknowledged the exact receipt while the worker remained alive;
workers received no completion message.

The owner approved local-only activation because Harnex currently has one
user. The exact verified gem is globally selected as local `0.12.1`, published
`0.12.0` remains installed as rollback, and the global executable repeated all
three smokes successfully with zero residual sessions. Public publication is
deferred: prescribed `bin/gem-push` reports `.env not found`, and no credential
workaround, tag, or Git push occurred. Keep this issue open as the public
release tracker; local runtime use is unblocked.

Source exposure: none — implementation and synthetic proofs stay local; no
private downstream source, incident logs, package, or Git objects were published.
