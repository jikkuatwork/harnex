# #36 — `--auto-stop` lingers `disconnected` before DISPATCH row emission

**Status:** Tier 2 landed (race bounded); follow-ups optional
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

## Tier 1 — diagnosis (2026-05-07, code-reading + events-log review)

The race is architectural, independent of how big the perceived gap
is:

1. **`harnex wait` watches the subprocess, not the parent.** In
   `wait_until_exit` (`lib/harnex/commands/wait.rb`), `target_pid`
   is `registry["pid"]`, which is the **agent subprocess** pid
   (codex app-server, or PTY child) — not the harnex parent. As
   soon as the subprocess dies, `Harnex.alive_pid?` returns false
   and `wait` calls `read_exit_status`, which falls through to a
   synthesized `{ok: true, status: "exited"}` if the exit-status
   file isn't on disk yet.

2. **The DISPATCH row is written in the parent, after subprocess
   death.** `Session#finalize_session!`
   (`lib/harnex/runtime/session.rb`) calls
   `append_summary_record` — the row writer — **after**
   `Process.wait2` unblocks. The ordering for both
   `run_jsonrpc` and `run_pty` is:

   ```
   subprocess dies
     → Process.wait2 returns in harnex parent
     → finalize_session!
         emit_session_end_telemetry  (git_capture_end)
         append_summary_record       ← DISPATCH row written
         emit_summary_event
         emit_exit_event
     → ensure: inbox.stop, server.stop, adapter.close
              persist_exit_status    ← exit-status file written
              cleanup_registry
   ```

   So `harnex wait` can return between "subprocess died" and "row
   appended", and the registry is still present when it does.

3. **`STATE=disconnected` in `harnex status` is the adapter's
   transient state, not a lifecycle state.** The status table
   reads `input_state.state`. For `CodexAppServer` that's the
   adapter's own `@state`, which is set to `:disconnected` when
   `JsonRpcClient.read_loop` hits EOF (i.e. the subprocess just
   died). It is **not** a session-lifecycle field; the state
   machine itself only has `prompt | busy | blocked | unknown`.
   So "status shows disconnected" really means "the subprocess
   has died and we are inside parent teardown."

4. **Auto-stop teardown chain (JSON-RPC).** `turn/completed` →
   `schedule_auto_stop` (Thread A) → `inject_stop` calls
   `adapter.interrupt` synchronously, then spawns Thread B for
   `terminate_subprocess` (SIGTERM 0.5s, SIGKILL 1.0s). Thread B
   kills codex, `read_loop` hits EOF (sets adapter state
   `:disconnected`, emits `disconnected` event), `Process.wait2`
   in the main thread unblocks, then `finalize_session!` runs.

5. **Magnitude check on the cx-d-readme run.** Events log
   `0d37a43c1c84fe87--cx-d-readme.jsonl`:

   ```
   seq=109 11:24:00Z task_complete
   seq=110 11:24:00Z disconnected (transport: "no active turn to interrupt")
   seq=111 11:24:00Z usage
   seq=112 11:24:00Z git phase=end
   seq=113 11:24:00Z summary path=…/DISPATCH.jsonl
   seq=114 11:24:00Z exited code=0 reason=success
   ```

   All teardown events land in the same UTC second. The
   "tens of seconds" framing in the original repro likely
   conflated the time *before* `turn/completed` (codex finishing
   its last reasoning + writing the done-file mid-turn) with the
   actual harnex teardown gap. **The architectural race remains
   real**, but the practical window in the observed run was
   sub-second. Event timestamps are second-precision
   (`Time.now.utc.iso8601`); millisecond-precision instrumentation
   would be needed to bound the gap any tighter.

## Tier 2 — recommended fix

**Make `harnex wait` (default) block until `exit_status_path`
exists.** The exit-status file is written in the run-loop ensure
block, *after* `finalize_session!` writes the row, so its
existence is a strict superset of "DISPATCH row on disk."

Concretely, in `Waiter#wait_until_exit`:

- When `alive_pid?(target_pid)` flips to false, instead of
  immediately calling `read_exit_status`, poll `File.exist?(exit_path)`
  with a short bounded grace (e.g. 5s, configurable).
- If the file appears, return its contents (existing path).
- If it never appears (parent crashed between row-write and exit-status
  write — pathological), fall back to the synthesized "exited" response
  so wait still terminates.

This is the smallest correct change and needs no schema or
adapter modifications. It also preserves the meaning of
`harnex wait` for orchestrators: "wait returned" ⟹ "DISPATCH row
is on disk."

**Optional follow-up** (not required for Tier 2 closure):

- Surface `--until row_emitted` as an explicit predicate that polls
  `koder/DISPATCH.jsonl` for a row matching `meta.id` +
  `meta.started_at`. Useful when the caller has the dispatch path
  in hand and wants to be transport-agnostic.
- Bump event timestamps to `iso8601(3)` (millisecond precision)
  so future regressions can be quantified directly from the
  events log.

## Done when

- Race window is bounded and documented, OR eliminated.
- An orchestrator can rely on a single barrier ("done-file present"
  OR "harnex wait returned") to safely read `koder/DISPATCH.jsonl`
  for the just-finished session.
- Regression test exercises the teardown ordering by:
  asserting that, after `wait_until_exit` returns, the DISPATCH
  file contains a row whose `meta.id` matches the session.

## Tier 2 — landed 2026-05-07

- `Waiter#wait_until_exit` (`lib/harnex/commands/wait.rb`) now polls
  `exit_status_path` for up to 5s after `alive_pid?(target_pid)`
  flips false, before calling `read_exit_status`. The exit-status
  file is written in the run-loop ensure block *after*
  `finalize_session!` appends the DISPATCH row, so its presence is
  a strict superset of "row on disk."
- Grace bound is `EXIT_STATUS_GRACE_SECONDS_DEFAULT = 5.0` with
  poll interval `0.05`; overridable via the
  `HARNEX_EXIT_STATUS_GRACE_SECONDS` env var (used by tests and
  available as an emergency knob in pathological teardowns).
- If the file never appears (parent crashed between row-write and
  exit-status write — pathological), the existing `read_exit_status`
  fallback synthesizes an `exited` response so `wait` still
  terminates.
- Regression test
  (`test/harnex/commands/wait_test.rb#test_wait_until_exit_blocks_until_exit_status_file_lands`)
  spawns a real subprocess, kills it, then writes a DISPATCH row +
  exit-status file in the production order with an inserted gap.
  Asserts that when `wait` returns, the DISPATCH row's
  `meta.id` matches the session id.
- Suite green: 399 runs, 1292 assertions.

## Optional follow-ups (not required for closure)

- `wait --until row_emitted` predicate that polls
  `koder/DISPATCH.jsonl` for `meta.id` + `meta.started_at` directly,
  for callers with the dispatch path in hand.
- Bump event timestamps to `iso8601(3)` (millisecond precision) so
  future regressions can be quantified directly from the events log.

## Out of scope

- DISPATCH row schema changes (covered by #35).
- New transports.

