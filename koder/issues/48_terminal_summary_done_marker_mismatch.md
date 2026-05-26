---
status: landed
priority: P1
---

# Issue 48 — Terminal summary should be canonical over tmp done markers

**Status**: landed
**Priority**: P1
**Filed**: 2026-05-25
**Source incident**: Holm Queue `007`, dispatch `cx-i-007-02`
**Related**: #42 durable app-server orchestrator recovery, #47 queue-aware dispatch telemetry

## Problem

A Holm queue run exposed a lifecycle mismatch: a Codex app-server dispatch
completed successfully and wrote terminal summary telemetry, but the queue
monitor kept treating it as still running because the expected `/tmp/*-done.txt`
marker was missing.

Observed in Holm repo during Queue `007`:

- dispatch id: `cx-i-007-02`
- harnex summary path:
  `koder/queue/007_security_policy_observability_cleanup/RUNS/cx-i-007-02.jsonl`
- summary fields included:
  - `actual.exit: "success"`
  - `actual.exit_code: 0`
  - `actual.task_complete: true`
  - `ended_at` populated
- no `/tmp/cx-i-007-02-done.txt` marker was present
- `scripts/harnex/sweep.sh` kept reporting the entry as `working`
- after the harnex session disappeared from active status, pane reads failed,
  but the monitor still classified it as `working`
- the orchestrator then blocked in a foreground wait loop until the wall-clock
  cap instead of returning control and checkpointing from durable telemetry

The code changes from the worker were valid and validation passed. The failure
was not the worker task; it was completion detection and orchestration recovery.

## Why this matters

Queue runners and orchestrators need a durable terminal truth. A temporary done
marker is too brittle to be the primary completion source. If harnex has already
written a successful terminal summary row, downstream tools should not keep
polling pane state or waiting for `/tmp` side effects.

This affects unattended Holm queues, but the problem is harnex-level:

- harnex owns dispatch lifecycle state
- harnex writes terminal summaries
- harnex status/wait/sweep consumers need one canonical terminal contract
- pane/tmux state should be a fallback, not the source of truth for structured
  adapters

## Desired behavior

Harnex should expose and/or enforce terminal completion in this priority order:

1. Durable harnex session/summary state.
2. `--summary-out` JSONL terminal row.
3. `.harnex` / repo-local dispatch log terminal row.
4. Legacy `/tmp/*-done.txt` marker.
5. Pane/tmux text as last-resort diagnostic only.

If a summary row says `task_complete=true`, `exit=success`, and `exit_code=0`,
the session is done even if the tmp done marker is missing.

If the session is no longer active and there is no terminal summary, harnex
should report `unknown` or `failed`, not `working`.

## Proposed fixes

### 1. Canonical machine-readable status

Add or harden a command such as:

```bash
harnex status --json --id <id>
harnex wait --json --id <id> --timeout <duration>
```

The JSON should include a durable terminal state:

```json
{
  "id": "cx-i-007-02",
  "state": "completed",
  "terminal": true,
  "task_complete": true,
  "exit": "success",
  "exit_code": 0,
  "summary_out": ".../cx-i-007-02.jsonl",
  "ended_at": "..."
}
```

### 2. Summary-out terminal detection

When a run uses `--summary-out`, harnex should be able to answer terminal state
from that file even if the session process/tmux pane is gone.

### 3. Stop treating pane failures as working

Current downstream sweep behavior treated pane read failures as `working`. The
harnex-side contract should make that unnecessary, but harnex docs/examples
should also state:

- active session + readable pane + no terminal row => maybe working
- no active session + terminal success row => done
- no active session + no terminal row => unknown/failed
- pane read failure alone must not create an infinite `working` state

### 4. Done-marker contract

Either:

- make harnex always write a done marker for every terminal path when requested,
  including structured app-server success paths; or
- demote done markers to compatibility hints and document terminal summaries as
  canonical.

The preferred direction is to make terminal summaries canonical and tmp markers
legacy/fallback.

### 5. Documentation / agents-guide update

Update `agents-guide monitoring` and related docs so queue/orchestrator loops do
not block on tmp markers alone. Include an explicit anti-pattern:

> Do not run foreground `while ! /tmp/done; sleep` waits as the orchestrator.
> Use harnex terminal status/summary checks and return control at checkpoints.

## Acceptance criteria

- [x] A dispatch with terminal `--summary-out` success is reported as completed
      even when the tmp done marker is absent.
- [x] `harnex status --json` or equivalent exposes `completed | failed |
      running | unknown` using durable terminal state, not pane text alone.
- [x] `harnex wait --json --id <id>` exits successfully for terminal summary
      success even if no done marker exists.
- [x] If a session is no longer active and no terminal summary exists, harnex
      reports `unknown` or `failed`, never indefinite `working`.
- [x] Docs/agents-guide monitoring examples stop relying on tmp done markers as
      the only completion signal.
- [x] Tests cover: summary success without done marker, active running without
      summary, missing session with no summary, and pane-read failure behavior.

## Resolution — 2026-05-26

Landed on `main`:

- Added `Harnex::TerminalStatus` (`lib/harnex/terminal_status.rb`) to resolve
  durable terminal state from dispatch summaries/history.
- `harnex status --json --id <id>` now returns one machine-readable row even
  after session teardown, using states `running | completed | failed | unknown`.
  For active sessions it emits `running`; for inactive sessions it falls back to
  summary/history (`terminal=true`) or `unknown` (`terminal=false`).
- `harnex wait --id <id>` now falls back to terminal summary/history when the
  live registry and exit-status file are absent, and succeeds for terminal
  summary success without any tmp done marker.
- Missing-session/no-summary waits now return machine-readable
  `{"state":"unknown","terminal":false}` instead of blocking on pane loops.
- Monitoring docs now treat tmp done markers as legacy hints, with terminal
  summaries/`status --json`/`wait` as canonical completion signals.

Coverage added/updated:

- `test/harnex/commands/status_test.rb`
  - terminal summary completion when session is inactive
  - `unknown` state when no live or terminal data exists
- `test/harnex/commands/wait_test.rb`
  - wait exit success from summary-only terminal row (no exit-status file)
  - unknown terminal response when no session/summary exists

Verification:

- Full suite green: 472 runs, 1543 assertions, 0 failures, 2 skips.

## Out of scope

- Building a full queue runner into harnex.
- Holm-specific queue metadata schema beyond #47.
- App-server stream recovery itself; #42 owns restart/resume after transport
  errors. This issue is about recognizing terminal completion and preventing
  false stuck monitors.
