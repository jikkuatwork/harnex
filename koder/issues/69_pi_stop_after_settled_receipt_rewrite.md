---
status: resolved
resolved: 2026-09-28
plan: 36
priority: P1
created: 2026-08-14
updated: 2026-09-28
tags: pi, rpc, stop, receipts, lifecycle, reliability
type: bug
issue_kind: slice
context: Stopping an idle Pi RPC session after accepted work rewrites its valid receipt and dispatch outcome as failure.
---

# Issue 69 — Pi explicit stop after settled work rewrites accepted proof as failure

## Problem

`harnex stop` against a persistent Pi RPC session that has already emitted an
accepted `task_complete` terminates the child with exit `143`. Finalization then
classifies the expected operator cleanup as a lost RPC transport, overwrites the
previously valid receipt with `status: fail`, and records the dispatch outcome as
rejected.

This makes the documented fire/watch/verify/stop lifecycle unsafe for persistent
Pi workers: valid completed work becomes failed proof solely because the operator
freed the session after verification.

## Evidence

External source: Holm Queue `121` Pi-adapter preflight on 2026-08-14 with Harnex
`0.11.0` and Pi `0.84.1`.

Session `pi-smoke-121-fallback` used `foundry-zyt/gpt-5.5` over
`stdio_jsonl_rpc`:

1. Initial turn emitted accepted `task_complete`; its requested artifact existed.
2. A follow-up `harnex send --wait-for-idle` completed and emitted a second
   accepted `task_complete`; its second artifact also existed.
3. `harnex stop --id pi-smoke-121-fallback` returned
   `{"ok":true,"signal":"interrupt_sent"}` while the worker was idle.
4. Final telemetry then reported exit `143`, `adapter_close: lost`, one
   disconnection, `outcome.status: rejected`, and an invalid final receipt whose
   observed turn still said `task_complete: true` but `accepted: false`.

A changed-shape retry using the same Pi/model route with `--auto-stop` completed
cleanly. Holm Q121 therefore prohibited persistent reuse and used fresh
`--auto-stop` workers only.

## Expected Direction

Preserve the last accepted settled turn when explicit stop is only post-work
cleanup:

- distinguish operator-requested idle shutdown from an unexpected transport
  disconnect;
- do not let TERM/exit `143` overwrite accepted task/receipt state after
  `agent_settled` when no newer turn is active;
- keep stop-during-busy semantics fail-closed (abort/interrupted work is not
  accepted);
- retain normal Git/usage finalization and remove the live registry/tmux entry.

## Acceptance Criteria

- [x] Persistent Pi RPC: accepted turn → idle → `harnex stop` leaves the final
      receipt valid and preserves `accepted`/`no_change` as observed before stop.
- [x] The dispatch end row classifies teardown as clean operator cleanup, not
      `adapter_close: lost` or a real disconnection.
- [x] A two-turn regression test proves follow-up completion is preserved after
      explicit idle stop.
- [x] Stop while Pi is busy still aborts/fails the active turn and cannot reuse a
      previous accepted turn as proof for unfinished work.
- [x] After stop, `harnex status` has no live session and terminal telemetry has
      one coherent end row.

## Resolution — 2026-09-28

Delivered in locally installed **0.14.0**, package source `aab0973`; implementation
is in `e429f6a`, with reviewed lifecycle/transport hardening through `78d3efa`.
Plan: `koder/plans/36_pi_idle_stop_preserves_settlement.md`.

The final installed-binary Pi 0.87.1 smoke completed two turns, validated both
artifacts and the receipt, then stopped while idle. Final proof remained accepted;
raw Pi exit was 143 without an OS signal, logical exit was 0, adapter close was
normal, real disconnections were zero, registry was gone, and exactly one end
row remained. Unexpected EOF, malformed/truncated output, and abnormal cleanup
still fail closed. A 3.2s local receipt gate no longer fabricates transport loss.

Full package-HEAD suite: 815 runs / 3,820 assertions / no failures or errors;
independent review approved. Public publication is separate and was not done.
Detailed evidence and limits: `koder/releases/0.14.0.md`.

## Non-Goals

- Changing the working Pi `--auto-stop` lifecycle.
- Pi PTY support (#45).
- Richer command-exit observation; tracked separately in #70.
