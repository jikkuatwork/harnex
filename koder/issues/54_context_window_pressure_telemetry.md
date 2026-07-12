---
status: open
priority: P1
issue_kind: slice
created: 2026-07-12
updated: 2026-07-12
tags: telemetry,context,usage,pi,codex,compaction
---

# Issue 54 — Capture active context-window pressure and high-water telemetry

## Problem

Harnex records cumulative dispatch usage, cost when supported, tool calls,
compactions, output volume, reliability, and accepted-work evidence. It does
not record how full the agent's active context became.

That distinction matters:

- cumulative input tokens measure all requests over time, not the context
  resident in the latest request;
- a cheap-looking dispatch can still approach its context limit;
- compaction can lower active context while cumulative usage continues rising;
- session-rotation policy needs current/peak context pressure, not only total
  tokens or cost.

The structured adapters already receive useful source data but discard it:

- Pi RPC `get_session_stats` returns
  `contextUsage.{tokens,contextWindow,percent}`. `Adapters::Pi` currently maps
  token totals, tool calls, cost, session id, model, and provider, but ignores
  `contextUsage`.
- Codex app-server `thread/tokenUsage/updated` includes
  `tokenUsage.modelContextWindow` and a `last` usage breakdown. Harnex stores
  the notification but serializes only cumulative `total` usage.

Therefore the current dispatch row can answer "how much usage accumulated?"
but not "how much context pressure did this session reach?"

## Goal

Add bounded, provenance-aware context-window telemetry for structured adapters,
separate from cumulative `usage` totals.

A possible additive summary shape is:

```json
{
  "context": {
    "status": "observed",
    "source": "pi_get_session_stats",
    "terminal_tokens": 64000,
    "window_tokens": 200000,
    "terminal_percent": 32.0,
    "peak_tokens": 118000,
    "peak_percent": 59.0,
    "samples": 7
  }
}
```

Exact names should converge in the plan. Required semantics:

- `terminal_*` describes the final valid sample, not cumulative usage;
- `peak_*` is the high-water mark across bounded samples;
- `status` distinguishes `observed`, `estimated`, `unsupported`, and `missing`;
- `source` identifies the adapter/provider signal used;
- null after compaction must not erase an earlier valid high-water sample;
- cumulative request tokens remain in `usage` and must not be mislabeled as
  context occupancy.

## Sampling policy

Prefer bounded sampling over verbose per-token telemetry:

- sample Pi after settled agent runs when Harnex already requests session stats;
- update an in-memory high-water mark rather than emitting every raw sample;
- record compaction before/after facts when the adapter exposes them;
- for Codex, document precisely whether `last` is provider-observed occupancy or
  only an estimate before deriving a percentage;
- never store prompt text, transcripts, tool payloads, or message bodies in the
  context block.

Threshold-crossing events may be useful later, but are not required for v1.

## Acceptance criteria

- [ ] Pi RPC maps `get_session_stats.contextUsage` into adapter summary state.
- [ ] Multiple Pi stats samples preserve terminal context and peak/high-water
      context independently.
- [ ] A null post-compaction Pi context sample does not erase the prior peak and
      is represented without pretending that null means zero.
- [ ] Dispatch summaries include an additive, stable context block with status
      and source provenance.
- [ ] Codex app-server captures `modelContextWindow`; any occupancy estimate
      derived from `last` usage has documented semantics and provenance.
- [ ] Unsupported adapters report `unsupported` rather than fabricated values.
- [ ] Tests cover observed, missing, unsupported, multi-sample high-water, and
      compaction/null behavior.
- [ ] `docs/dispatch-telemetry.md` explains the difference between cumulative
      usage and active context pressure.
- [ ] Existing summary consumers remain compatible.

## Out of scope

- Capturing a primary interactive orchestrator that is not launched through
  Harnex; tracked separately in #55.
- Automatic compaction or session rotation policy.
- Prompt/message/tool-result content capture.
- Queue-level orchestration-cost rollups.
- Retrofitting historical rows.

## Relationship to existing work

- #44 introduced Pi RPC and already identified `get_session_stats` context
  usage as available protocol data.
- #43 and plan 31 added usage provenance, attempts, attribution, and outcomes;
  this issue keeps active context pressure separate from cumulative usage.
- #42 concerns durable orchestrator recovery. Recovery and rotation decisions
  need this signal but should not be implemented in this telemetry slice.

## Triage

- **Tier**: B
- **Estimated sessions**: 1–2
- **Risk**: medium; schema work is additive, but adapter-specific context
  semantics must not be overstated.
