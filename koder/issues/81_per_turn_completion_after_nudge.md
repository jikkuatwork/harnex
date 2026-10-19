---
status: open
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
