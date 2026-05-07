# #36 — `--auto-stop` lingers `disconnected` before DISPATCH row emission

**Status:** open
**Priority:** P3
**Filed:** 2026-05-07

## Why

A `--auto-stop` worker writes its task return artefact (e.g. its
done-file) and signals "I am done", but the harnex session itself
stays in `disconnected` state for tens of seconds before the row
lands in `koder/DISPATCH.jsonl`. The DISPATCH row is only written
on full session teardown.

This produces an observable race for orchestrators that poll a
return file:

1. Done-file appears → orchestrator proceeds.
2. `harnex status` still shows the session: `state=disconnected`.
3. `koder/DISPATCH.jsonl` last row is the *previous* dispatch.
4. Some seconds later, the session finally exits and the row is
   appended.

If the orchestrator inspects DISPATCH between (1) and (4), it sees
no row for the dispatch it just verified. This can fool a reviewer
into flagging a "missing telemetry" failure that does not exist —
or, worse, into discarding rows that are about to land.

## Repro (observed 2026-05-07)

- Dispatched `cx-d-readme` via
  `harnex run codex --id cx-d-readme --tmux cx-d-readme --detach
  --auto-stop --context "..."`.
- Worker wrote `/tmp/cx-d-readme-done.txt` with `STATUS: green`.
- Immediately after: `harnex status` showed
  `cx-d-readme codex … 4m 18s disconnected …`.
- `tail -1 koder/DISPATCH.jsonl` → still the prior `quality-audit`
  row.
- Ran `harnex stop --id cx-d-readme` → "no session found" (it had
  just exited in the gap).
- `wc -l koder/DISPATCH.jsonl` → +1, with the `cx-d-readme` row
  finally present.

## Hypothesis

`--auto-stop` flips the lifecycle on the first task-complete signal
(landed in 0.6.5, see `koder/issues/15_*` and `koder/releases/0.6.5.md`).
The teardown path that flushes the DISPATCH row may be running in a
worker thread that takes a long tail (subprocess exit, JSON-RPC stop
ack, file flush) before `Session#emit_dispatch_row` actually runs.
During that tail the session is in `disconnected` and no row is on
disk.

Worth checking:

- Is `emit_dispatch_row` called inside the auto-stop teardown path,
  or only from the normal exit path? If the latter, auto-stop may
  rely on `disconnected → exit` transition to trigger row emission,
  and that transition is what lags.
- Is the JSON-RPC `app-server` stop subprocess teardown waiting on a
  child reap that doesn't return promptly?
- For PTY adapters, is the wait the same or shorter?

## Why it matters

- Reviewer dispatches that verify "did this run produce a DISPATCH
  row?" become flaky.
- Orchestrators that bundle dispatch rows into commits race the
  teardown.
- The `disconnected` state is not visible to a buddy that is
  watching only the worker's task signals — the buddy thinks
  the worker is done but the session is leaking.

## Tier 1 — diagnose

- Repro deterministically with `--auto-stop` on both transports
  (PTY and JSON-RPC) and time the gap from done-signal → row on
  disk.
- Add structured logging at session teardown: when does
  `disconnected` enter, when does the row write?
- Confirm whether `harnex wait --id <id>` blocks until row-on-disk
  or only until lifecycle exit.

## Tier 2 — fix candidates

- Move DISPATCH row emission earlier in the auto-stop path, before
  the long subprocess-teardown tail.
- Or: keep emission where it is but expose a separate
  `wait --until row_emitted` so callers can pick the right barrier.
- Or: have `harnex wait` (default behavior) guarantee the row is on
  disk before returning.

## Out of scope

- DISPATCH row schema changes (covered by #35).
- New transports.

## Done when

- Race window is bounded and documented, OR eliminated.
- An orchestrator can rely on a single barrier ("done-file present"
  OR "harnex wait returned") to safely read `koder/DISPATCH.jsonl`
  for the just-finished session.
- Regression test exercises the teardown ordering.
