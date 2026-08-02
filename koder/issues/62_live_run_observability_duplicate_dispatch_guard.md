---
status: done
priority: P1
issue_kind: slice
created: 2026-08-02
updated: 2026-08-02
tags: observability, dispatch, wait, status, history, registry, retry, queue, reliability
---

# Issue 62 — Live dispatches are invisible; coordinators respawn healthy workers

## Problem

Between launch and teardown, a harnex dispatch has no durable trace and is
unreliably visible to `status`/`history`/`wait` from another session's
context. A monitor that checks mid-run concludes the worker is dead and
dispatches a duplicate — which then runs concurrently in the same checkout.

Holm Queue `096` (`~/Projects/holmhq/holm/master`, 2026-08-02) hit this three
times in one row; the queue-global process budget (3) then blocked the queue
with six rows untouched. Zero product failures. Reconciliation:
`.harnex/reports/cx-r-096-process01.json`; program plan:
`koder/plans/708_S00_process_mechanization_mapping/INDEX.md` (Holm).

Timeline of the first event (coordinator `cx-m-096c01`, worker `cx-t-096-01`
started 10:38:14Z, ended cleanly 10:44:01Z `task_complete`, report written
10:43:28Z):

- 10:40:02 `harnex status --json --id cx-t-096-01` → coordinator read
  "registration looks incomplete"
- 10:40:08 `harnex history --limit 10` → no row for the dispatch (rows are
  written only in `finalize_session!`)
- 10:40:50 `harnex status` → worker "disappeared from active status"
- 10:41:06 `harnex wait --id cx-t-096-01 --until done --timeout 1800` →
  returned within ~5s instead of blocking
- 10:41:12 `harnex artifact-report validate … --final` → report missing
  (worker still mid-run)
- 10:41:45 coordinator dispatched duplicate `cx-t-096-01-r1` while the
  original was alive

Same pattern for `cx-i-096-01-r1` (+81s into a 3.3min run) and
`cx-cr-096-01-r1` (+88s into a 2.3min run).

Code anchors (0.7.14):

- Rows only at teardown: `lib/harnex/runtime/session.rb:1271-1291`
  (`finalize_session!`); no start record exists anywhere.
- Registry deleted for dead pids and invisible windows:
  `lib/harnex/core.rb:269` (`active_sessions` unlink).
- `repo_key` derivation can diverge between writer and reader:
  `lib/harnex/core.rb:242-246`; summary path (`core.rb:117-122`) vs history
  path (`lib/harnex/dispatch_history.rb:16-23`) resolve from different roots
  (`repo_root` vs launch cwd git-toplevel).
- `status` silently falls back to a stale registry row on any HTTP error:
  `lib/harnex/commands/status.rb:134-148`.
- Waiter: `lib/harnex/commands/wait.rb:232-300`; exit 1 conflates
  "no signal found" with "work failed" and "proof rejected".
- Related prior art: #36 (autostop dispatch-row race), #57 (outcome classes).

## Goal

1. **Dispatch-start record.** At registration, append a durable start row
   (id, `started_at`, meta, pid, `schema_version`) to the dispatch stream so
   a running session always has a trace; the teardown row completes it.
2. **Live visibility.** `harnex status --id`, `harnex history`, and
   `harnex wait` must correctly see a running session launched from any cwd/
   context in the same repo: one canonical path/`repo_key` resolution for all
   writers and readers; no silent stale-registry fallback (label degraded
   data as degraded).
3. **`wait --until done` contract.** While the session's pid is alive, wait
   blocks (up to `--timeout`). Terminal exit codes/payload must distinguish:
   completed-with-accepted-work / completed-rejected-proof / failed /
   timeout / no-such-session. "No signal yet" while alive is not terminal.
4. **Duplicate-dispatch guard.** `harnex run` with `--attempt-kind retry`
   or a `--parent-dispatch-id` naming a live session refuses to dispatch
   (clear error naming the live parent, override flag for intentional
   parallelism).

## Acceptance Criteria

- A test reproduces the Q096 shape: worker session mid-run, checker in a
  separate process/cwd. Checker observes `status` = running, `history` has
  the start row, `wait --until done` blocks until the worker finishes, and a
  retry dispatch is refused while the parent lives.
- Start+end rows validate against the dispatch-row schema test
  (`test/dispatch_row_schema_test.rb`) extended for the start shape.
- Exit-code contract for `wait` documented in `guides/04_monitoring.md` and
  covered by tests for each terminal class.
- No monitor consulting only documented signals can classify a healthy
  mid-run worker as dead.

## Resolution (2026-08-02)

All four goals implemented; unreleased on main pending the next gem release.

1. **Dispatch-start record** — `DispatchHistory.build_start_record` appended
   at registration in both `run_pty` and `run_structured`
   (`session.rb#append_dispatch_start_record`); end rows gained
   `record_type: "dispatch_end"` and `session_id` for pairing. Both rows go
   through `dispatch_history_path` keyed off the session's `repo_root` (was
   launch cwd) so writers and readers resolve one canonical stream.
   `Harnex.repo_key` now canonicalizes via realpath (`canonical_repo_root`).
2. **Live visibility** — `harnex history` pairs start/end rows and renders
   unpaired starts as `running`/`interrupted`; `harnex status` labels
   degraded sources (`source: live|registry|dispatch_start`,
   `degraded: true`) and falls back to the live start record before terminal
   summaries; `DispatchHistory.live_start_record` (host + pid alive checked)
   is the shared liveness reader.
3. **`wait --until done` contract** — exit codes 0 done / 1 failed /
   2 rejected proof / 3 no-such-session / 124 timeout, `wait_result` in every
   payload, liveness re-checked each poll (registry → start record), stale
   exit files and stale events from a same-id predecessor ignored while a
   live session is in view. Documented in `guides/04_monitoring.md`.
4. **Duplicate-dispatch guard** — `Runner#validate_live_parent_guard!`:
   retry requires `--parent-dispatch-id`; retry/fix/superseding naming a
   live parent in the same repo are refused (review exempt);
   `--allow-live-parent` overrides and is forwarded through tmux
   re-invocation. Guard reads only explicit metadata, never the implicit
   `HARNEX_ID` spawner lineage.

Acceptance test: `test/integration/live_run_observability_test.rb`
reproduces the Q096 shape end-to-end (worker mid-run, checkers in a separate
process/cwd, registry deleted mid-run, wait blocking through completion,
retry refused then allowed). Schema coverage in
`test/dispatch_row_schema_test.rb` (start-row shape + pairing) and
`test/harnex/dispatch_history_test.rb`.
