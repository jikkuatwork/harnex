---
status: open
priority: P1
created: 2026-05-06
tags: telemetry,dispatch,jsonrpc,observability,quality
---

# Issue 32: DISPATCH telemetry row not written when session fails before lifecycle teardown

## Summary

When a JSON-RPC session disconnects very early (e.g., the `0.6.2` schema
mismatch killed sessions at `seq:3`, ~1s post-spawn), no row is written to
`koder/DISPATCH.jsonl` for that dispatch. The failure is invisible in the
telemetry ledger.

This was discovered during the `0.6.2` stress test on 2026-05-06: 4
JSON-RPC stress sessions (`cx-stress-1` through `cx-stress-4`) all
disconnected at `seq:3` with `Invalid request: invalid type: null,
expected a string`. The orchestrator confirmed the deaths via tmux
capture and the `telemetry sessions` JSON, but **none of the 4
appear in `DISPATCH.jsonl`**. Only `cx-stress-pty` (the `--legacy-pty`
control, which booted) and `cx-spike-1` (post-patch) have rows.

The user's own `cx-impl-018` first-attempt registration earlier the
same day also vanished from DISPATCH.jsonl for the same reason.

## Why this matters

DISPATCH.jsonl is the cross-session ledger. If early-boot failures
don't land in it:

- **Failure rate is invisible.** "X% of dispatches died at boot" is
  not derivable from the file.
- **Re-occurrence detection breaks.** If `0.6.4` re-introduces a
  similar boot bug, no telemetry alarm fires — failures simply don't
  exist in the data.
- **The gap is correlated with the worst failures.** Successes, cleanly-
  finished failures, and stalls all get rows. Early-boot transport
  errors — the *worst* failure mode — are the ones we lose. This is
  the inverse of what observability should do.

This is a sibling defect to #30 (test schema truth): tests said `0.6.2`
worked, telemetry would have caught the lie if it had recorded the
failures. Both protections were absent.

## What "fixed" looks like

1. **Always write a DISPATCH row at session-end**, regardless of how
   the session ended. The row should be written from a `begin/ensure`
   block (or equivalent) wrapping the lifecycle, so even an early
   transport error or unexpected exception still produces a row with:
   - `meta.id`, `meta.tmux_session`, `meta.harness_version`,
     `meta.started_at`, `meta.ended_at`
   - `actual.exit` set to `disconnected` / `boot_failure` / `crashed`
     as appropriate
   - `actual.disconnections` incremented
   - `actual.duration_s` (even if very small)
   - Tokens / LOC fields can be null — that's fine, exit reason is
     the load-bearing field.

2. **Distinguish `boot_failure` from `disconnected`**. `cx-spike-1` got
   `exit: "disconnected"` after running for 62s. The 4 `cx-stress-*`
   deaths at `seq:3` are qualitatively different: the session never
   reached steady state. A new exit code (`boot_failure` or
   `early_disconnect`, criterion: disconnected before
   `task_started` or before N seconds) makes that visible without
   reading raw events.

3. **Optional but valuable: capture the last N protocol events** in
   the row when exit is `boot_failure`. The schema-mismatch error
   `Invalid request: invalid type: null, expected a string` was
   visible at `seq:3` but only via raw `harnex telemetry sessions`
   inspection. Embedding `actual.last_error` or `actual.boot_events`
   (last 5 events) in the row would make the next regression
   self-diagnosing.

## Repro

```bash
# On harnex 0.6.2 (pre-0.6.3 fix):
harnex run codex --tmux cx-repro-1 --id cx-repro-1 \
  --summary-out /tmp/dispatch.jsonl \
  --context "echo OK" \
  -- -m gpt-5.5-mini -c model_reasoning_effort=low
sleep 5
cat /tmp/dispatch.jsonl   # empty — no row for cx-repro-1
harnex telemetry sessions --id cx-repro-1   # disconnect at seq:3 visible here
```

Expected: a row in `/tmp/dispatch.jsonl` with `exit: "boot_failure"`,
`disconnections: 1`, `duration_s: ~1`.

## Related

- #29 (closed, fixed in 0.6.3) — the schema mismatch this exposed.
- #30 (open, P1) — the test-schema-truth gap that let `#29` ship broken.
- #31 (open, P2) — `inject_exit` no-op for JSON-RPC; another lifecycle
  gap on the same adapter.
- holm #272 (SESSION.jsonl record drift) — downstream consumer; without
  this fix, the harness rollup proposed there will silently undercount
  failures.
