---
status: resolved
priority: P2
created: 2026-10-19
updated: 2026-10-20
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

## Decisions (owner, 2026-10-20) — ready for autonomous implementation

- **Pi: deliver as a follow-up.** A non-`--force` send to a busy Pi session is
  handed to Pi at once as `streamingBehavior: "followUp"`; Pi queues it and
  delivers it when the current run ends, so the Harnex TTL never applies. Send
  exits 0 once Pi accepts it (report the disposition). `--force` keeps steering
  mid-turn.
- **Every adapter: fail loudly on expiry.** A queued message that expires
  undelivered makes `harnex send` return at once with `status: "expired"`,
  `error: "expired undelivered after Ns; agent busy; use --force to inject
  mid-turn"`, and a non-zero exit, instead of polling until its own timeout.

## Resolution

Shipped in 0.18.0 (local install). A busy Pi session takes a send at once as
a Pi follow-up (`delivery: "follow_up"`); turn results report
`follow_ups: {sent, pending}`. For other adapters an expired message makes
`send` exit 1 (`status: "expired"`), and a send that times out withdraws its
message before exiting 124. Verified live in a Claude subagent dogfood run.
