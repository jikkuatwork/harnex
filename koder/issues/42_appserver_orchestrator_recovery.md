---
status: open
priority: P1
---

# Issue 42 — Durable app-server orchestrator recovery

**Status**: open
**Priority**: P1
**Filed**: 2026-05-13
**Tier**: B (plan -> impl -> verification)
**Sister**: builds on #27 (Codex app-server adapter), #41
(`Harnex::Codex::AppServer` extraction), and plan 30 Phase 2
(subprocess restart + `thread/resume`). Related to #40, but this issue
targets same-deployment orchestrator durability rather than alternate
deployment fallback.

## Problem

The operator wants to use Codex as both orchestrator and worker. A
visible PTY/TUI orchestrator is convenient, but it is the wrong place
to hold critical coordination state: when the TUI stream breaks, the
orchestrator itself can stall or die.

The preferred architecture is to make the visible TUI an initiator /
controller and run the real orchestrator as a harnex-managed Codex
`app-server` session. That orchestrator should survive the largest
known failure class: response-stream errors and JSON-RPC transport
disconnects.

Current harnex behavior is not enough for this role. `harnex run codex`
uses `codex app-server` by default and records `disconnected` events,
but a final stream error or transport loss can still end the harnex
session. The app-server restart/resume primitives exist; the missing
piece is a supervisor policy that decides when and how to restart,
resume, and continue.

## Decision

Do **not** start with a PTY regex sentry. PTY string matching remains a
possible fallback for visible workers later, but the orchestrator
should use structured app-server signals first.

## Goal

Add an opt-in durable app-server orchestrator mode that:

- detects stream errors from JSON-RPC `error` notifications and
  transport disconnects
- respects Codex's `willRetry` signal so harnex does not double-recover
  while Codex is retrying internally
- restarts the `codex app-server` subprocess after a final recoverable
  stream failure
- resumes the prior `threadId`
- dispatches a bounded recovery prompt so the orchestrator inspects
  repo/events state and continues without duplicating completed work
- records timestamped telemetry for stream errors and recovery attempts

## Proposed surface

Exact CLI shape should be finalized in the plan, but the initial sketch:

```bash
harnex run codex --auto-recover --context "orchestrate issue 42..."
```

Possible additional guards:

- `--recover-max-attempts N`
- `--recover-cooldown DUR`
- `--recover-prompt PATH`

Default remains off.

## Implementation sketch

1. Fix JSON-RPC error parsing in `Session#handle_rpc_notification`.
   Current code reads `params["message"]`; the current schema carries
   the message under `params["error"]["message"]` and type information
   under `params["error"]["codexErrorInfo"]`.
2. Add a small stream-error classifier for app-server notifications:
   `responseStreamConnectionFailed`, `responseStreamDisconnected`,
   `responseTooManyFailedAttempts`, and transport EOF.
3. Add a same-deployment recovery path that reuses the existing
   app-server restart/resume machinery:
   stop old subprocess -> spawn fresh `codex app-server` with the same
   command/env/cwd -> initialize -> `thread/resume`.
4. After resume, dispatch a recovery prompt rather than attempting to
   replay opaque in-flight bytes.
5. Guard the loop with max attempts, cooldown/backoff, and clear final
   escalation.
6. Keep plan 30's alternate-deployment fallback separate. This issue
   recovers the orchestrator on the same deployment first; #40 can later
   switch deployments based on disconnect-rate thresholds.

## Telemetry

Add high-fidelity events:

- `stream_error`
- `orchestrator_recovery_attempted`
- `orchestrator_recovery_succeeded`
- `orchestrator_recovery_failed`

Each event should include the normal `ts` and enough structured detail
to debug policy decisions:

- `source`: `error_notification` / `transport`
- `codex_error_info`
- `message`
- `will_retry`
- `attempt`
- `threadId`
- `turnId` when known

Add summary-row counters / fields:

- `stream_errors`
- `orchestrator_recoveries_attempted`
- `orchestrator_recoveries_succeeded`
- `orchestrator_recoveries_failed`
- `first_stream_error_at`
- `last_stream_error_at`

## Acceptance criteria

- App-server orchestrator recovery is opt-in and disabled by default.
- A simulated final `responseStreamDisconnected` error causes harnex to
  emit `stream_error`, restart the subprocess, call `thread/resume`
  with the original thread id, emit recovery telemetry, and continue to
  accept/dispatch turns.
- A simulated error with `willRetry: true` records telemetry but does
  not restart the subprocess.
- A simulated transport EOF during an active orchestrator session
  follows the same restart/resume path when within retry limits.
- Recovery attempts are bounded; once exhausted, the session exits with
  explicit failure telemetry rather than looping forever.
- Dispatch summary rows expose the aggregate stream-error/recovery
  counters and first/last stream-error timestamps.

## Open questions for plan-write

1. Should this be a plain `--auto-recover` flag or an
   orchestrator-specific mode such as `--orchestrator`?
2. After `thread/resume`, should harnex always inject a recovery prompt,
   or can Codex resume the interrupted turn without a new prompt in some
   cases?
3. Should recovery prompt text be fixed for v1, configurable, or both?
4. Should the supervisor live in `Session`, in
   `Harnex::Codex::AppServer`, or as a new
   `Harnex::Codex::AppServer::Supervisor`?
5. What is the minimum durable checkpoint format needed for an
   orchestrator that spawned workers before the stream error?

## Out of scope

- PTY/TUI regex sentry for stream-error strings.
- Alternate-deployment fallback (#40 / plan 30).
- Whole-process supervision if the Ruby harnex process itself crashes.
  That likely needs a later outer `harnex supervise` layer.
- Multi-fallback chains or model/provider switching.
