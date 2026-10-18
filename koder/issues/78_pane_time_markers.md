---
status: open
priority: P2
created: 2026-10-18
updated: 2026-10-18
tags: pane, tmux, observability, stalls
issue_kind: slice
type: feature
---

# Issue 78 — Time markers in rendered panes so a stuck session is obvious

Replaces #45's underlying need (owner, 2026-10-18): "Not needed [a Pi TUI],
but i wish to have some time markers every ~5 minutes / after every ~30 lines
or so; so that when i look at that pane, i know whether its stuck or not".

## Decisions (owner, 2026-10-18) — ready for autonomous implementation

- **Trigger:** a dim ruler line after every ~30 rendered lines **or** every
  5 minutes since the last ruler, whichever comes first. The time trigger
  fires even when nothing prints, which is how silence shows up as a stall.
- **Content:** clock time, run age, time since last activity, e.g.
  `── 14:05 · running 12m · last activity 8s ago ──`. Last activity comes from
  the structured activity clocks (the same notion as `Harnex::Stall`). Use
  local wall-clock `HH:MM`.
- **Where:** Harnex's rendered output for structured adapters (Pi RPC; Codex
  app-server if ever used), meaning the tmux pane / foreground terminal (the
  `STDOUT` writes in `Session`), and also the transcript (`harnex logs`).
  **Never** inject into a PTY adapter's TUI stream (it would corrupt the
  screen).
- No change to events JSONL, receipts or dispatch rows. Markers carry no model
  content.
- Thresholds are constants (30 lines / 300 s) and may get env overrides; no new
  CLI flags needed.

## Acceptance

- In a live `harnex run pi --tmux` session, the pane shows rulers on both
  triggers, including during a silent command.
- PTY adapters are unaffected (test asserts no ruler in PTY output).
- Hermetic tests for the line counter, the timer and the formatting.
