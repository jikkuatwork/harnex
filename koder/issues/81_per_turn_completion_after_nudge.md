---
status: resolved
priority: P1
created: 2026-10-20
updated: 2026-10-20
tags: wait, send, owner-stream, orchestration, retry
issue_kind: slice
type: feature
related: 72, 77, 79
---

# Issue 81 — Wait for the next turn's completion after a nudge

Holm's capacity rule (Queue 159) is: when a pi turn fails on provider capacity, nudge once with
`harnex send --id X --message "Continue the same task from where you stopped"`, then wait for
that turn. Today the supervisor cannot wait for it:

- `harnex wait --id X --until done` scans events from session start
  (`lib/harnex/commands/wait.rb`, `scan_events(..., min_ts: session_started_at)`), so it returns
  at once on the earlier `task_failed`.
- The completion notifier fires once per session (`lib/harnex/runtime/completion_notifier.rb`,
  `@notified`), so the #77 owner stream never reports the nudged turn either.

So a supervisor (and especially a Claude Code subagent, which cannot be woken later) has to fall
back to polling the state column.

Want: per-turn completion. Either `harnex wait --id X --until done --after-seq N` (or
`--after-turn <turn_id>`, with `send` printing the turn id and event seq it injected), or
`harnex send --wait-done` that blocks until the turn it started completes or fails. Also emit one
owner-stream event per turn completion, not one per session.

## Decisions (owner, 2026-10-20) — ready for autonomous implementation

- **Both entry points, one primitive.** `harnex send` reports the event seq it
  injected at (`after_seq`). `harnex wait --until done --after-seq N` ignores
  every terminal event at or before seq N and waits for the next turn's
  completion or failure. `harnex send --wait-done` combines the two in one call.
- **Owner stream: one event per turn.** The completion notifier and the #77
  owner stream report every completed or failed turn (with its seq/turn id),
  not one event per session. The cursor keys on the turn, so a nudged turn is
  delivered too.

## Resolution

Shipped in 0.18.0 (local install): `send` reports `after_seq`,
`wait --until done --after-seq N`, `send --wait-done`, `turn` on terminal
events, and one owner-stream result per turn (cursor keyed on the turn, timed
from the turn's start). Verified live by a Claude subagent.
