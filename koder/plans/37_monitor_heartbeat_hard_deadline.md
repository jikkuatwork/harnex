---
status: in_progress
issue: 71
plan: 37
layer: unattended-completion-reliability
created: 2026-09-28
updated: 2026-09-28
---

# Plan 37 — Streamed monitor heartbeat and hard observer deadlines

Bounded follow-up to completed Plan 35. This is an observer contract, not a worker
runtime budget or prompt-as-completion heuristic. See Issue #71 and Plan 38.

## Contract

- `wait` and `watch --heartbeat DUR` opt in to flushed diagnostic progress lines
  on stderr; normal JSON stdout and default behavior remain compatible.
- `wait --timeout` / `--max-wait` and `watch --max-wait` bound the entire observing
  operation with a monotonic deadline, including slow registry/status/event reads
  and post-exit grace. Exit 124 once; never stop the worker on observer timeout.
- Heartbeats describe observed wait/state/event facts, never invent model progress.
- TerminalWatcher must not globally replace stdout/stderr or buffer heartbeats
  until completion. Preserve typed result codes and compatibility markers.

## Execution and proof

1. RED tests: heartbeat visible before completion; default JSON-only output;
   invalid intervals; slow status, event, and exit-grace operations cannot extend
   the cap; no monitor thread/process leak; correct terminal results.
2. Implement focused wait/watch changes with explicit output streams and bounded
   probes; avoid a scheduler, polling daemon, or unbounded teardown join.
3. Update bundled monitoring help/guide. Run focused tests and full suite.
4. Integrate with Plans 36/38, independent review, and installed CLI smoke.

Use deterministic clocks/probes where possible plus one process-level real-time
cap test. Acceptance target: process returns within configured cap plus one poll
and modest scheduling tolerance under deliberately slow probes. Do not claim
universal OS scheduling or uninterruptible-kernel guarantees.
