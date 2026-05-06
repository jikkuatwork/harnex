---
status: resolved
---

# Issue 23 — Dispatch telemetry: capture token / duration / cost actuals

**Status**: open
**Priority**: P2
**Filed**: 2026-04-30
**Tier**: B (plan → impl → diff-sanity, no separate review session)

## Problem

When dispatching agents (especially Codex), there is no mechanical record of:

- input / output / reasoning / cached tokens used
- duration / wall time
- cost (USD) — derivable from tokens × per-model price
- code change footprint (LOC added/removed, files changed, commits)
- operational health (stalls, force-resumes, disconnects, compactions)

This blocks empirical calibration of the consumer side's dispatch
recommendations table (in holm: `knowledge-base/codex/recommendations.md`).
Without per-dispatch actuals, predicted ranges cannot be refined from
real data.

## Goal

Extend harnex so that every Codex dispatch produces a complete telemetry record
on session end, suitable for predicted-vs-actual analysis. The record should
land in:

1. The existing **events stream**
   (`~/.local/state/harnex/events/<repo>--<id>.jsonl`) as new event types
   (additive — schema_version stays `1` per the v1 stability promise in
   `docs/events.md`).
2. A **consolidated summary record** at a project-local path (default
   `<repo>/koder/DISPATCH.jsonl`) — one JSON line per dispatch combining
   meta + predicted + actual blocks.

## Authoritative schema

The target shape for the consolidated record is frozen in the consumer
project (holm):

`/home/glasscube/Projects/holmhq/holm/master/koder/DISPATCH.schema.md`

Three top-level blocks: `meta`, `predicted`, `actual`. Plan should treat that
file as the contract — implement what is required, leave non-extractable
fields explicitly `null`.

## Existing infrastructure (must respect)

- **`harnex events`** (v0.4.0, plan 26 just shipped): JSONL stream with
  envelope `{schema_version, seq, ts, id, type}`. Currently emits `started`,
  `send`, `exited`. See `docs/events.md`.
- **Schema stability promise**: v1 is additive-only. New event types and
  new fields may be added; existing fields cannot be removed/renamed/
  type-changed.
- **Outstanding L4 contract debt**: Layer 2 watcher does not yet emit
  `resume` / `log_active` / `log_idle` events into the JSONL stream. Plan
  should NOT block on closing that gap, but the new event types added by
  this issue must coexist cleanly with the watcher's eventual additions.
- **Codex adapter** (`lib/harnex/adapters/codex.rb`): owns prompt
  detection, banner latching, send-readiness. Likely the right place to
  hook session-end summary parsing.
- **Output transcript** at `~/.local/state/harnex/output/<repo>--<id>.log`
  contains the raw mirrored pane output, including codex's session-end
  summary block (whatever it looks like — verify during plan-write).
- **`harnex run --watch`** preset already polls for stalls; resume/disconnect
  events are the kind of operational health the new schema captures.

## Open design questions (plan-write must answer)

1. **Capture mechanism**: parse the codex session-end summary from the
   transcript at exit? Probe codex's JSON output mode if one exists? Hook
   into the codex JSON-rpc / session API if available? The plan must
   identify what codex actually emits at session end (run a probe session
   if needed) and pick the cleanest extraction strategy.
2. **Output channel**: extend the events stream with new event types
   (e.g. `usage`, `git`, `summary`)? Write a separate consolidated
   summary file via `--summary-out PATH`? **Both** (recommended — events
   for raw fidelity, summary for downstream tooling)?
3. **Predicted-data input**: predicted-data input is raw JSON via
   `--meta` only. The orchestrator passes
   `--meta '{"model":"gpt-5.3-codex","effort":"high","predicted":{...}}'`.
   Harnex does not resolve named dispatch buckets or read a lookup file. The
   consumer's `recommendations.md` table guides what predicted ranges to
   pass, but harnex remains unaware of that table.
4. **LOC capture**: harnex doesn't currently know about git. Add minimal
   git awareness (`start_sha` recorded at dispatch, `end_sha` recorded at
   exit, `git diff --shortstat` run at exit)? Or leave LOC capture to a
   post-session shim invoked by the consumer?
5. **Cost calculation**: per-model price table — where does it live?
   - Inside harnex (centralized, harnex maintains); pro: consumers don't
     duplicate; con: harnex now tracks pricing
   - In the consumer's recommendation metadata (per-consumer, pluggable); pro: harnex
     stays generic; con: each consumer maintains
   - Always nullable in `actual.cost_usd`, computed downstream by the
     consumer; pro: cleanest separation; con: extra pipeline step
6. **Multi-adapter generalization**: codex emits tokens; the claude adapter
   may emit a different format. Should the new event types be adapter-
   agnostic (each adapter fills in what it can), or codex-first with
   explicit non-applicability for other adapters?
7. **Failure modes**: what happens when codex disconnects mid-session and
   no session-end summary appears? Partial record with `exit: "disconnected"`
   and null token counts? How does this interact with `--watch`'s
   force-resume behavior (which restarts the same session and may cause
   summary-block parsing to double-count)?

## Acceptance criteria

- New CLI flags accepted by `harnex run`:
  - `--summary-out <path>` (default `<repo>/koder/DISPATCH.jsonl` if a
    project's `koder/` directory exists)
  - `--meta '{"model":"...","effort":"...","predicted":{...}}'` for
    predicted-range passthrough
- On session end, harnex emits new event types into the events stream
  with all token / duration / op-health fields populated.
- harnex writes one complete consolidated record to the summary file with
  `meta`, `predicted`, `actual` blocks per the schema doc — non-extractable
  fields explicitly `null`.
- Existing dispatches that don't pass predicted metadata continue to work
  unchanged. No regression on the 235-test suite.
- New tests cover:
  - End-to-end capture path on a mock codex session
  - Predicted passthrough with and without `predicted` metadata provided
  - Non-extractable field nullability
  - Schema additive-only check (envelope still valid for legacy consumers)
- New behavior documented (extend `docs/events.md` and/or add
  `docs/dispatch-telemetry.md`).

## Out of scope

- Calibration / analysis of the resulting JSONL (deferred to consumer until
  ~10 records exist).
- Predicted range population in any consumer's recommendations table.
- Cost ceiling enforcement / dispatch refusal.
- Multi-agent (claude / aider) telemetry — codex first; design should
  not foreclose later expansion.
- Retroactive ingestion of older sessions (transcripts may not exist).

## Triage (per `chain-triage.md` style)

- **Tier**: B
- **Reasoning**: introduces a new capture surface localized to codex
  adapter + events emitter + a new summary writer; failure modes are
  recoverable (lost telemetry on a crash isn't data-loss); no schema
  migrations to existing tables; events schema stays at v1 additive.
- **Phases**: plan → impl → diff-sanity (no separate code-review session)
- **Plan count**: 1
- **Estimated sessions**: 2-3 (plan, impl, fix-if-needed)
- **Estimated wall-clock**: ~2h end-to-end

## Consumer reference

- holm recommendations table: `knowledge-base/codex/recommendations.md` (in holm repo)
- holm DISPATCH schema: `koder/DISPATCH.schema.md` (in holm repo)

These ship in holm's Phase 1 (separate dispatch, parallel to this issue's
plan-write).

## Notes

- This is the first harnex feature driven by a downstream consumer's
  empirical needs. The design should generalize — consumers choose their
  own recommendation systems, and harnex only accepts raw `--meta`
  predicted data without any name-resolution layer.
- Events schema additions count as a Layer 5 contribution to the events
  bus (Layer 4 was the bus itself). Document accordingly.
