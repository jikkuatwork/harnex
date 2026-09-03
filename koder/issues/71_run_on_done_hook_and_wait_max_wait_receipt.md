---
status: open
priority: P1
created: 2026-09-03
updated: 2026-09-03
tags: pi, watch, wait, lifecycle, notification, orchestration, unattended
type: feature
issue_kind: slice
plan: 35
context: On 2026-09-02/03 a Holm Pi worker (pi-b-862s2) finished with a stop-rule report at 00:18 IST and sat at a prompt for 7 hours; the orchestrator's single `harnex watch --until done --max-wait 24m` call never returned to the orchestrator until 07:12. No harnex surface pushed the completion or the stop-rule to a human.
---

# Issue 71 — session-owned completion push signals: `--on-done` hook + default marker + loud rejected state

## Problem

Harnex's completion contract is **pull-only**: `wait`/`watch` block a caller
until `done`. When the caller is an LLM orchestrator whose own tool call can
be swallowed by the harness (observed: a 24m `--max-wait` call that did not
surface to the orchestrator for ~8h; harnex's own `timeout` JSON was never
seen), nothing else fires. The worker had already:

- emitted `task_complete` (seq 423, `2026-09-02T18:48:45Z` = 00:18 IST),
- written a receipt with `status: fail` / `outcome.status: rejected`,
- printed a structured report including `stop-rule-hit: no-network rail`,

and then parked at a prompt. Harnex knew the work was done. Nobody was told.
The user woke to a live session and 7h of nothing.

**Correction (2026-09-03, verified against the state files):** at the
`task_complete` instant (seq 423) harnex's typed view was `completed` with
`artifact_report_status: accepted`. The receipt's `status: fail` /
`outcome.status: rejected` was written at `02:03:43Z` by `harnex stop`
(`exited code: 143`), not at 00:18. The stop-rule failure existed only in the
worker's prose report, which harnex does not classify. So the push signal for
this incident would have been `completed`; that is sufficient because it wakes
the orchestrator, who reads the report. The stop-time rewrite of accepted
proof is the #69 family.

Evidence (Holm repo): `.harnex/dispatch.jsonl` rows for `pi-b-862s2`
(`dispatch_start 17:33:00Z`, `dispatch_end 02:03:42Z` = when the orchestrator
finally ran `harnex stop`); events log
`~/.local/state/harnex/events/829f11fd3f06ce6d--pi-b-862s2.jsonl`; receipt
`…-pi-b-862s2-31999daa42dff386.json`.

## Required Direction

1. **`harnex run … --on-done <cmd>`** (one hook with a typed `$HARNEX_OUTCOME`;
   no separate `--on-fail` surface). Fires once, from the harnex runner process —
   not from the orchestrator — when the session reaches `done` (accepted or
   rejected), `task_failed`, or `dispatch_error`. Env passed to the hook:
   `HARNEX_ID`, `HARNEX_OUTCOME` (`completed|rejected|failed|error`),
   `HARNEX_WORK_STATE`, `HARNEX_RECEIPT_PATH`, `HARNEX_END_SHA`,
   `HARNEX_ELAPSED_S`. Typical use: `--on-done 'agent-speak "worker $HARNEX_ID
   $HARNEX_OUTCOME"'` or `--on-done 'touch /tmp/pi-b-862s2.done'`. This turns
   completion into a push signal that survives orchestrator absence.
2. **`--on-done` default marker**: even without a hook, write
   `<state>/done/<repo-hash>--<id>.<outcome>` so a dumb `ls`/inotify can see
   completion without parsing events.
3. **[deferred — not in Plan 35]** `wait`/`watch --heartbeat <dur>`: while
   blocked, print one line per interval (`waited=… state=… last_event=… seq=…`)
   so a caller whose stdout is streamed can distinguish "still waiting" from
   "hung". Default off for JSON consumers; `--heartbeat 60s` recommended in the
   agents-guide for LLM callers.
4. **[deferred — not in Plan 35]** `--max-wait` must be a hard promise:
   `wait_until_done` already has a deadline; add a test that the process exits
   within `max-wait + poll` even when `live_session`/`scan_events` are slow
   (stat/parse of a 140 KB events file every tick). `--exit-on-prompt` is
   **rejected** as a solution: prompt state is not completion proof, and the
   source incident already emitted `task_complete`.
5. **Settled work is loud in the live table**: the incident's `dispatch_end`
   row carries its (stop-time) rejection in the nested `outcome.status`
   block (top-level `status` stays `completed` — the session did complete; no
   schema fork). The live gap is that `harnex status` rendered the worker as
   `prompt` for seven hours although its `work_state` was already `completed`.
   Fix: the status table must render settled work state — `done` (accepted
   completion), `rejected` (proof rejection / rejected observed receipt),
   `failed` (other typed task failure) — over the adapter's `prompt` input
   state, so a glance tells an operator this worker needs a decision, not more
   waiting.

## Acceptance (Plan 35 scope)

- `harnex run pi --context … --on-done 'echo $HARNEX_OUTCOME >> /tmp/x'` with a
  fixture Pi that emits `task_complete` → `/tmp/x` gets exactly one line;
  same for `task_failed` and `dispatch_error` (one unified hook).
- Hook fires when no `wait`/`watch` client is attached.
- A live rejected worker renders `rejected`, and a live completed worker
  renders `done` (not `prompt`), in the `harnex status` table.
- `harnex agents-guide monitoring` documents: unattended dispatch =
  `--on-done` hook + bounded `watch` calls; never a single long blocking call.

Deferred to later plan IDs: `wait`/`watch --heartbeat`, hard `--max-wait`
enforcement, and any prompt-based exit.

## Plan sequencing

Plan 35 (`koder/plans/35_completion_push_signals.md`) is the first bounded
slice: session-owned default markers, one unified `--on-done` hook, and loud
rejected-work visibility. It deliberately leaves heartbeat streaming and hard
`--max-wait` enforcement for later monotonic plan IDs. `--exit-on-prompt` is
not planned because prompt state is not completion proof and would not address
the source incident, which already emitted `task_complete`.

Issue #71 remains open after Plan 35 until those monitor-hardening slices are
planned and delivered.

## Non-Goals

Not a scheduler, not a daemon; the hook runs once from the existing runner
process. No new telemetry stream (Issue 63 stands).
