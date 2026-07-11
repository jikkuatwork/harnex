---
status: open
priority: P1
---

# Issue 46 — Restore dispatch cost telemetry by default

**Status**: open
**Priority**: P1
**Filed**: 2026-05-23
**Tier**: B (plan -> impl -> verification)
**Sister**: related to #35 (telemetry hygiene), #43 (throughput-first telemetry v2), and #44 (Pi RPC adapter).

## Problem

#35 removed `actual.cost_usd` because the field was always null for the then-active adapters. With Pi becoming the operator's primary harness, cost is now available through Pi's structured stats (`get_session_stats.cost`) and should be restored as first-class dispatch telemetry.

The operator expects Pi to be the default path for most work and wants cost emitted by default when the adapter/provider exposes it.

## Goal

Restore cost telemetry in DISPATCH summary rows as an additive, populated field:

- `actual.cost_usd` — numeric provider/harness-reported USD cost for the run when available, else `nil`

Use Pi RPC as the first high-confidence source. Other adapters can populate it later if they gain reliable structured cost data.

## Remaining telemetry gap — 2026-07-11

The original restoration is shipped, but cost provenance is still ambiguous for
queue analysis. A `null` `actual.cost_usd` can currently mean that the adapter
is unsupported, that a supported provider did not return cost, or that the
summary did not receive a usage observation. Consumers also need to distinguish
observed provider cost from future estimated cost, without treating missing
cost as zero.

Extend the existing summary contract rather than adding another telemetry
writer. Add a top-level `usage` block while retaining `actual.*` fields for
compatibility:

```json
{
  "usage": {
    "status": "observed",
    "cost_usd": 1.42,
    "cost_source": "provider_reported",
    "input_tokens": 120000,
    "output_tokens": 8000,
    "total_tokens": 130000
  }
}
```

Recommended statuses are `observed`, `estimated`, `unsupported`, `missing`,
and `zero`. Preserve `null` when no numeric amount is known. Keep raw usage
separate per retry/fix/review dispatch so later queue aggregation can avoid
double-counting one accepted result.

## Design constraints

- Do **not** block #44 on cross-provider perfect cost normalization.
- Treat Pi's `get_session_stats.cost` as authoritative for Pi sessions.
- Keep schema additive and backward-compatible.
- Document semantics clearly: provider/harness-reported approximate USD, not a billing invoice.
- Preserve nil when an adapter cannot provide a reliable cost.

## Proposed implementation

1. Add `actual.cost_usd` back to the dispatch summary schema/tests.
2. Add a session-level cost summary slot, populated by structured adapters.
3. For Pi RPC (#44), call `get_session_stats` at session end and assign `stats["cost"]` to `actual.cost_usd` when numeric.
4. Leave Codex/Claude/OpenCode PTY adapters nil unless a reliable source exists.
5. Update `docs/dispatch-telemetry.md`, README telemetry notes if applicable, and schema tests.
6. Include cost in any future `harnex history` display only if it can be done without noisy formatting changes; otherwise keep JSONL-only for this slice.

## Acceptance criteria

- Dispatch summary rows include `actual.cost_usd` again.
- Pi RPC sessions populate `actual.cost_usd` from Pi structured stats.
- Adapters without reliable cost data emit `null` rather than guessing.
- Schema regression test covers the restored field.
- Docs define the field and explain that it is provider/harness-reported approximate USD.
- Existing telemetry consumers remain compatible with the additive field.
- [ ] Usage status distinguishes observed, estimated, unsupported, missing, and
      explicit zero cost without converting unavailable cost to `0`.
- [ ] A top-level `usage` block documents cost provenance while preserving
      `actual.cost_usd` compatibility.
- [ ] Tests cover observed, unsupported, missing, zero, and estimated-status
      serialization, including Pi RPC usage fixtures.
- [ ] Retry/fix/review dispatches retain separate raw cost and token values with
      stable parent relationships for deduplicated queue analysis.

## Out of scope

- Cross-provider canonical normalization / exchange-rate-style reconciliation.
- Retrofitting historical DISPATCH rows.
- Cost forecasts or budget enforcement.
- Reintroducing other #35 removed fields (`actual.tests_*`, `meta.agent_deployment`) unless separately justified.

## Triage

- **Tier**: B
- **Plan count**: can be implemented as part of #44 or as a small follow-up
- **Estimated sessions**: 0.5–1
- **Estimated wall-clock**: ~1–2h

## Notes

This intentionally reverses only the cost part of #35. The earlier removal was correct for always-null telemetry, but Pi changes the default data availability profile.
