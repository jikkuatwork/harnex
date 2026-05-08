# #37 — `--auto-stop` teardown leak leaves `harnex run` alive

**Status:** Tier 2 landed
**Priority:** P2
**Filed:** 2026-05-08

## Why

`harnex run --auto-stop` must be a bounded one-shot dispatch surface:
after the first `task_complete`, the runner should stop Codex, flush the
summary/DISPATCH row, write the exit-status file, remove the registry
entry, and exit. Holm observed the opposite during F23 atlas filing:
the Codex subprocess was gone and the dispatch row existed, but the
wrapping Ruby `harnex run` process remained asleep on `futex_wait_queue`
inside a surviving tmux window. `harnex doctor --sweep` correctly
reported that as `orphan_tmux`; this issue fixes the producer-side
teardown leak.

## Repro

Observed 2026-05-08 from Holm:

```text
harnex run codex --auto-stop --until task_complete --context "..."
  -> task_complete observed
  -> dispatch row written
  -> codex subprocess gone
  -> harnex run parent remains alive in tmux
  -> doctor --sweep reports orphan_tmux
```

The `--until` flag belongs to `harnex wait`, not `harnex run`. That
unknown-flag passthrough is F24 and remains out of scope here.

Regression test added here:

```text
test_auto_stop_exits_when_jsonrpc_interrupt_never_answers
```

The test runs a real `bin/harnex run codex --auto-stop` subprocess with
a fake `codex app-server`. The fake server emits `turn/completed`, then
never answers `turn/interrupt`. Before the fix, the harnex process did
not exit within 10s.

## Hypothesis

The auto-stop path had an unbounded RPC wait:

```text
turn/completed
  -> schedule_auto_stop
  -> inject_stop
  -> adapter.interrupt(turn/interrupt)   # synchronous
  -> adapter.terminate_subprocess        # only reached after interrupt returns
```

If Codex never answers `turn/interrupt`, harnex never reaches the
existing bounded TERM/KILL fallback. Separately,
`JsonRpcClient#signal_disconnect` notified the session but did not fail
pending request queues, so an in-flight request could remain blocked
after transport EOF until a later explicit `close`.

## Tier 1 diagnosis

Code trace:

1. `Session#handle_rpc_notification("turn/completed")` emits
   `task_complete` and calls `schedule_auto_stop`.
2. `schedule_auto_stop` starts a Ruby thread that calls `inject_stop`.
3. For JSON-RPC adapters, `inject_stop` called `adapter.interrupt`
   synchronously before it started `terminate_subprocess`.
4. `CodexAppServer::JsonRpcClient#request` blocks on a `Queue#pop`
   until the matching response arrives.
5. On transport EOF, `signal_disconnect` did not clear or fail
   `@pending`, leaving blocked requests to wait.

The live Holm orphan process was already past row emission when it was
inspected, so the exact historical stack is not available. The shipped
fix bounds both relevant leak shapes: a stop path that never reaches
subprocess termination, and an auto-stop helper thread that survives
after process teardown.

## Tier 2 fix

Landed 2026-05-08:

- `Session#inject_stop` now starts JSON-RPC subprocess termination
  before waiting for the `turn/interrupt` RPC result, so an unanswered
  interrupt cannot prevent the TERM/KILL fallback from running.
- `CodexAppServer::JsonRpcClient#signal_disconnect` now fails every
  pending request queue when the transport disconnects.
- Auto-stop helper threads are tracked and drained before finalization.
  The drain is bounded by
  `HARNEX_AUTOSTOP_TEARDOWN_GRACE_SECONDS`, default `5.0`.
- If the grace is exceeded, harnex emits an
  `auto_stop_teardown_timeout` event, kills the helper thread, and
  returns a non-zero exit code.
- Clean auto-stop completion normalizes the harnex runner exit code to
  `0` even when the child app-server was intentionally terminated.

## Done when

- A JSON-RPC `--auto-stop` dispatch exits after `task_complete` even if
  `turn/interrupt` never replies.
- The DISPATCH row is written before the runner exits.
- No active harnex registry row or orphan tmux window remains for the
  dispatch id.
- The focused regression and adjacent runtime suite pass.

## Optional follow-ups

- F24 causal link: **inconclusive**. The new test confirms that an
  unanswered interrupt can reproduce the teardown hang class, but this
  dispatch did not fix or deeply trace unknown-flag passthrough.
- Add millisecond event timestamps so future teardown races can be
  quantified directly from events logs.

## Out of scope

- F24 unknown-flag rejection for `harnex run`.
- `harnex doctor --sweep` detection behavior.
- Release/version bump.
