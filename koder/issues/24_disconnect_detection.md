---
status: superseded
---

# Issue 24 — Layer 5: codex stream-disconnect detection

**Status**: closed (harnex 0.6.0)
**Priority**: P1
**Filed**: 2026-04-30
**Superseded by**: `27_codex_appserver_adapter.md` (2026-05-06)
**Tier**: B (plan → impl → diff-sanity)
**Sister**: extends issue 22 (built-in dispatch monitoring) — explicitly deferred from L4 close as Layer 5.

> **2026-05-06 — Closed by construction via Issue 27.**
> The architectural pivot to `codex app-server` JSON-RPC transport
> replaces pane regex matching with structured `error` notifications
> from the server. Detection is no longer heuristic; it is delivered
> by Codex itself as a typed event. The acceptance criteria below
> (90s detection latency, regex matching, frozen-token heuristic) all
> become irrelevant when the transport is RPC. See
> `27_codex_appserver_adapter.md` for the rebuild plan.

## Problem

Codex sessions running against Azure deployments occasionally lose their stream
mid-reasoning. The TUI keeps the spinner alive (cosmetic repaint) but no new
tool calls are made and token counters freeze. harnex's current monitoring
cannot distinguish this from "Codex is genuinely thinking":

- `log_mtime` keeps updating because the TUI repaints (so `log_idle_s` stays low)
- `agent_state` stays `busy` because the spinner is visible
- Force-resume injections queue in the input bar and never flush — Codex is
  already gone from the stream, so submit-on-prompt never fires
- Net result: sessions stall indefinitely; orchestrator-level monitors must
  cap force-resumes manually and stop the session

This was deferred at the close of issue 22 with the note:
> Layer 5 (deferred): disconnect-regex detection. File as separate issue if
> real-world stalls show disconnect dominates.

## Evidence

**Live incident** — `cx-p-h23` dispatch (2026-04-30, plan-write for harnex
issue 23):

- Wall time: 34m 30s
- Productive work: ~7min (investigation per brief)
- Silent stall: ~26min
- Token counters frozen at 355K input / 2.71K output for the full 26min
- 3 orchestrator-level force-resumes injected at ~19m / ~25m / ~32m — none
  flushed
- 0 commits, 0 file output
- Wasted ~$X tokens (will be quantifiable once issue 23 lands)

The pattern: investigation phase produced visible output, then Codex entered a
single-turn reasoning phase and never emerged. The bench (`gpt-5.5 high` P3
hard-reason: 16–22s expected) suggests the silent phase was a stream cut, not
deep thinking — a 26-min reasoning cycle is implausible.

## Existing infrastructure

- `harnex events --id` (v0.4.0, plan 26) — JSONL stream; new `disconnected`
  event would be additive (schema_version stays 1)
- `harnex run --watch --preset` (v0.4.0, plan 24) — has `--stall-after`
  threshold but stall is detected via `log_idle_s` only; doesn't help here
- `lib/harnex/adapters/codex.rb` — already latches `@banner_seen` on initial
  detection; this issue extends adapter responsibilities to track
  connection liveness
- `lib/harnex/runtime/session.rb` — owns the PTY + state machine; right place
  to plumb disconnect-detection callbacks

## Goal

Detect codex stream-disconnect reliably and emit a `disconnected` event (with
metadata) so orchestrators / monitors can stop the session, optionally restart,
and record telemetry.

## Open design questions (plan-write must answer)

1. **Detection signal**: which heuristic is most reliable?
   - Regex against pane content for known disconnect markers (e.g.
     "Connection lost", "Stream interrupted", "Reconnecting…", or codex-
     specific banners)
   - Token-counter-frozen heuristic — read the codex-emitted token-usage
     hints from the pane every N seconds; if input/output unchanged for
     >X minutes despite `agent_state=busy`, mark disconnected
   - Combination: regex first (cheap), heuristic as fallback
   - Plan should run codex source spelunking + manual disconnect probes
     to identify the literal markers

2. **Detection latency**: target < how long? Recommend ≤ 90s after onset.

3. **Action on detection**:
   - Emit `disconnected` event into the JSONL stream (mandatory)
   - Auto-stop the harnex session? Or surface and let orchestrator decide?
   - Auto-restart the codex session via stored session ID (codex 0.125.0
     supports session resume)?
   - The plan should pick a single primary action and document the others
     as future expansion.

4. **Cost ceiling**: should harnex cap reasoning time hard (e.g.
   `--max-reasoning-s 600` flag)? This would catch genuine stalls AND
   runaway reasoning. Or strictly leave caps to the cost surface (issue 23)?

5. **Multi-adapter generalization**: is this codex-specific, or is the same
   pattern likely on claude / future adapters? Plan should propose a base-
   adapter contract or a codex-only initial scope.

6. **Coexistence with `--watch`**: does the babysitter loop already have a
   hook point for "session went disconnected"? Plan must integrate cleanly.

## Acceptance criteria

- New event type `disconnected` in the events stream with payload like:
  ```json
  {"type": "disconnected", "detector": "regex|frozen-tokens|both",
   "evidence": "<short string>", "duration_s": 247}
  ```
- Detection within 90s of disconnect onset on the live incident pattern
- New `harnex status` field surfacing connection liveness (boolean or enum)
- Existing dispatches without disconnect events behave unchanged
- New tests cover: regex matching with mock pane, frozen-token heuristic
  with mock token-counter sequence, disconnect-event emission in events file
- Documented in `docs/events.md` and (likely) a new `docs/disconnect-
  detection.md`

## Out of scope

- Auto-restart logic (deferred — pick once detection is solid)
- Cost-ceiling enforcement (issue 23 territory)
- Other-adapter (claude / aider) disconnect coverage — codex-first

## Triage

- **Tier**: B
- **Reasoning**: new detection abstraction localized to adapter +
  events emitter; failure modes recoverable; events schema additive.
- **Phases**: plan → impl → diff-sanity
- **Plan count**: 1
- **Estimated sessions**: 2-3
- **Estimated wall-clock**: ~2h

## Relationship to issue 23

Issue 23 (dispatch telemetry) records stalls/disconnects as *operational
health* fields (`stalls`, `disconnections`, `force_resumes`). Issue 24 is the
**detection** that makes those fields populate accurately. Both can ship
independently — telemetry without disconnect detection still records token
counts; disconnect detection without telemetry still emits the event for
monitors. Sequencing is up to the orchestrator.

## Notes

- The cx-p-h23 incident on 2026-04-30 is the canonical reproducer. Pane log
  preserved at: `/home/glasscube/.local/state/harnex/output/0d37a43c1c84fe87--cx-p-h23.log`
  (6.4MB+). Events JSONL at: `/home/glasscube/.local/state/harnex/events/0d37a43c1c84fe87--cx-p-h23.jsonl`
- Plan-write should examine these artifacts to identify the literal pattern.
