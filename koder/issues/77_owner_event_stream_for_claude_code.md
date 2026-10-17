---
status: open
priority: P3
created: 2026-10-17
updated: 2026-10-17
tags: watch, notifications, claude-code, supervisors
issue_kind: slice
type: feature
---

# Issue 77 — One owner-scoped event stream for Claude Code supervisors

Requested from Holm, 2026-10-17 (owner: "if you need to change harnex in any way to make these
agents work easily, file an issue there"). Not urgent; Holm works around it today.

## Problem

Pi supervisors get owner-addressed completion through `.pi/extensions/harnex-wake.ts` (#72).
A Claude Code supervisor has no consumer, so Holm runs one hand-written poller per worker (a
bash loop over `harnex status --json` with its own 25-minute stall rule) as a Claude Code
background task. Each poller only reports at exit, knows one session, and re-implements stall
detection. Claude Code can turn each stdout line of a long-running command into a native
notification (its `Monitor` tool) and show a status line or panel from a command, but harnex
has no compact, owner-wide stream to feed either.

## Want

- **One stream per owner:** a command (for example `harnex watch --owner <id>`, or
  `harnex events --owner <id> --compact`) that emits one JSON line per lifecycle change of every
  dispatch the owner started: started, at prompt, done, failed, proof-rejected, stalled
  (#76's signal), timed out, stopped. No heartbeat lines by default, so a consumer is woken only
  when something needs a decision.
- **Owner identity without Pi:** `--orchestration-session-id` already exists (#72); document the
  Claude Code path (pass the Claude session id explicitly) and make sure a non-Pi owner gets the
  same per-attempt records and settlement.
- **A documented `harnex status --json` shape** for status-line consumers (id, work_state,
  agent_state, idle seconds, age, description), so a panel can depend on it.

## Acceptance

- With three concurrent dispatches under one owner, the stream emits exactly one line per
  terminal event per dispatch, and one `stalled` line for a session silent past the threshold.
- A Claude Code `Monitor` on the stream receives those lines as notifications; nothing else.
- A non-Pi owner's records settle the same way as a Pi owner's (#72 tests extended).

## Non-goals

No scheduler or queue changes; no change to Pi delivery; no Claude Code plugin code in harnex
(Holm owns its consumer: a `harnex-dispatch` agent type and a Workers panel).
