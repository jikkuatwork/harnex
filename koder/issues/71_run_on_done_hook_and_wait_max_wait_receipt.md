---
status: open
priority: P1
created: 2026-09-03
updated: 2026-09-03
tags: pi, watch, wait, lifecycle, notification, orchestration, unattended
type: feature
issue_kind: slice
context: On 2026-09-02/03 a Holm Pi worker (pi-b-862s2) finished with a stop-rule report at 00:18 IST and sat at a prompt for 7 hours; the orchestrator's single `harnex watch --until done --max-wait 24m` call never returned to the orchestrator until 07:12. No harnex surface pushed the completion or the stop-rule to a human.
---

# Issue 71 — `harnex run --on-done <cmd>` + `wait/watch` heartbeat: a finished worker must be able to page someone

## Problem

Harnex's completion contract is **pull-only**: `wait`/`watch` block a caller
until `done`. When the caller is an LLM orchestrator whose own tool call can
be swallowed by the harness (observed: a 24m `--max-wait` call that did not
surface to the orchestrator for ~8h; harnex's own `timeout` JSON was never
seen), nothing else fires. The worker had already:

- emitted `task_complete` (seq 423, `2026-09-02T18:48:45Z` = 00:18 IST),
- written a receipt with `status: fail` / `outcome.status: rejected`,
- printed a structured report including `stop-rule-hit: no-network rail`,

and then parked at a prompt. Harnex knew the work was done and had failed a
gate. Nobody was told. The user woke to a live session and 7h of nothing.

Evidence (Holm repo): `.harnex/dispatch.jsonl` rows for `pi-b-862s2`
(`dispatch_start 17:33:00Z`, `dispatch_end 02:03:42Z` = when the orchestrator
finally ran `harnex stop`); events log
`~/.local/state/harnex/events/829f11fd3f06ce6d--pi-b-862s2.jsonl`; receipt
`…-pi-b-862s2-31999daa42dff386.json`.

## Required Direction

1. **`harnex run … --on-done <cmd>`** (and `--on-fail <cmd>`, or one hook
   with `$HARNEX_OUTCOME`). Fires once, from the harnex runner process — not
   from the orchestrator — when the session reaches `done` (accepted or
   rejected), `task_failed`, or `dispatch_error`. Env passed to the hook:
   `HARNEX_ID`, `HARNEX_OUTCOME` (`completed|rejected|failed|error`),
   `HARNEX_WORK_STATE`, `HARNEX_RECEIPT_PATH`, `HARNEX_END_SHA`,
   `HARNEX_ELAPSED_S`. Typical use: `--on-done 'agent-speak "worker $HARNEX_ID
   $HARNEX_OUTCOME"'` or `--on-done 'touch /tmp/pi-b-862s2.done'`. This turns
   completion into a push signal that survives orchestrator absence.
2. **`--on-done` default marker**: even without a hook, write
   `<state>/done/<repo-hash>--<id>.<outcome>` so a dumb `ls`/inotify can see
   completion without parsing events.
3. **`wait`/`watch --heartbeat <dur>`**: while blocked, print one
   line per interval (`waited=… state=… last_event=… seq=…`) so a caller
   whose stdout is streamed can distinguish "still waiting" from "hung".
   Default off for JSON consumers; `--heartbeat 60s` recommended in the
   agents-guide for LLM callers.
4. **`--max-wait` must be a hard promise**: `wait_until_done` already has a
   deadline; add a test that the process exits within `max-wait + poll` even
   when `live_session`/`scan_events` are slow (stat/parse of a 140 KB events
   file every tick). Consider `--exit-on-prompt`: return when the agent state
   goes to `prompt` after `task_complete`, since for Pi RPC "done + prompt" is
   the terminal shape (`docs/pi-rpc.md`).
5. **Rejected receipts are loud**: when `outcome.status == rejected`, `watch`
   summary and the `dispatch_end` row should carry `outcome_class: rejected`
   (the Holm row shows only `status: completed`), and `harnex status` should
   flag the session (`STATE` column `done!`/`rejected`), so a glance at the
   table tells an operator this worker needs a decision, not more waiting.

## Acceptance

- `harnex run pi --context … --on-done 'echo $HARNEX_OUTCOME >> /tmp/x'` with a
  fixture Pi that emits `task_complete` → `/tmp/x` gets exactly one line;
  same for `task_failed` and `dispatch_error` (`--on-fail` or unified hook).
- Hook fires when no `wait`/`watch` client is attached.
- `harnex wait --until done --max-wait 5s --heartbeat 1s` against a session
  that never completes prints ≥4 heartbeat lines and exits `timeout` within
  6s.
- `dispatch_end` row for a rejected receipt carries a machine-readable
  rejected outcome; `harnex status` marks it.
- `harnex agents-guide monitoring` documents: unattended dispatch =
  `--on-done` hook + bounded `watch` calls; never a single long blocking call.

## Non-Goals

Not a scheduler, not a daemon; the hook runs once from the existing runner
process. No new telemetry stream (Issue 63 stands).
