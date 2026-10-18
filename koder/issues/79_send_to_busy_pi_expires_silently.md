---
status: open
priority: P2
created: 2026-10-19
updated: 2026-10-19
tags: send, inbox, pi, orchestration
issue_kind: slice
type: bug
---

# Issue 79 — `harnex send` to a busy pi session expires unread, and the sender is not told

Observed from a Holm overnight orchestrator (Queue 159, 2026-10-19). A `harnex send --id
pi-move-1019 --message "..."` to a pi worker that was mid-turn (long implementation turn) queued
the note, blocked the sender for the full 120 s timeout, then dropped it: `harnex status --json`
later showed `inbox: {pending: 0, delivered_total: 0, expired_total: 1}`. The worker never saw
the note (a scope addition about a security refusal). A second send to another busy worker
behaved the same. `--force` delivered at once (`delivered_total: 1`).

Problem: the default send to a busy agent is a silent loss path. pi sessions run turns of 30-60
minutes, far longer than the 120 s inbox TTL, so "queue until idle" almost never delivers, and
the sender's exit status gave no clear failure.

Want: when a queued message expires undelivered, `harnex send` exits non-zero with
"expired undelivered after Ns; agent busy; use --force to inject mid-turn" (or the pi adapter
delivers queued messages as a pi follow-up/steer message instead of waiting for a prompt).
Either way the orchestrator must learn that a note was lost.
