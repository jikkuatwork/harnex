---
status: closed
priority: P1
issue_kind: track
created: 2026-07-12
updated: 2026-07-15
tags: telemetry,orchestrator,queue,context,cost,rotation
---

# Issue 55 — Measure primary-orchestrator context and queue orchestration tax

## Problem

Harnex has increasingly strong telemetry for workers it launches: usage,
provider/model, cost provenance, duration, retries, reliability, queue
attribution, parent attempts, git outcomes, and typed artifact reports.

The primary orchestrator is often outside that boundary. A user may run Pi,
Claude, or Codex interactively and use it to launch dozens of Harnex workers.
Child rows can name `orchestrator`, `orchestrator_session`, `chain_id`, and
`parent_dispatch_id`, but those fields are attribution labels; they do not
measure the primary session itself.

Consequences:

- primary context size and high-water pressure are invisible;
- primary input/output/cache usage and cost are absent or unjoinable;
- compactions and context rotations split one logical queue drain into
  unrelated harness sessions;
- tool-call and control-plane output volume cannot be compared with accepted
  worker outcomes;
- a queue can look worker-efficient while spending substantial context on
  dispatch, polling, review routing, run-log updates, and reopen overhead.

For example, a long queue may generate many review/fix dispatches while the
primary remains implementation-blind. Existing telemetry shows the child work,
but cannot answer whether the primary stayed light.

## Goal

Represent one logical orchestration run across zero or more primary-session
generations, join it to child dispatches, and compute bounded queue-level
"orchestration tax" metrics without capturing conversation content.

The design should support two producer shapes:

1. a primary orchestrator launched through Harnex, where normal dispatch
   telemetry can be attributed as the root run;
2. an external interactive orchestrator, where an explicit integration (for
   example a Pi extension or small CLI producer) emits bounded lifecycle and
   usage samples.

Do not require global hooks. Unsupported harnesses must degrade explicitly.

## Proposed logical model

A logical orchestration run needs stable identity across session rotation:

```text
orchestration_run_id
  generation 1: primary session A
  generation 2: primary session B after clean rotation
  generation 3: primary session C after recovery
  child dispatches: plans/tests/implementation/reviews/fixes
```

A bounded producer event could carry:

```json
{
  "schema": "harnex.orchestrator_sample.v1",
  "orchestration_run_id": "...",
  "generation_id": "...",
  "project_id": "holm",
  "queue_id": "089",
  "session_id": "...",
  "event": "sample",
  "context": {
    "tokens": 64000,
    "window_tokens": 200000,
    "percent": 32.0
  },
  "usage": {
    "input_tokens": 120000,
    "output_tokens": 9000,
    "cached_input_tokens": 80000,
    "cost_usd": null,
    "status": "observed"
  },
  "tool_calls": 31,
  "compactions": 1
}
```

Exact schema and storage should converge in a plan. Samples must never contain
prompts, transcripts, tool arguments/results, secrets, or private payloads.

## Required rollups

Given a logical orchestration run and its child dispatches, a query or command
should be able to report:

- primary usage/cost with provenance;
- worker usage/cost with provenance;
- primary terminal and peak context by generation;
- primary turns/tool calls/compactions when available;
- generation count, clean rotations, recoveries, and rotation reasons;
- accepted, rejected, blocked, and unknown child outcomes;
- primary usage/tool calls per accepted queue entry;
- total orchestration wall time versus child active time;
- missing/unsupported coverage rather than treating absence as zero.

Call this "orchestration tax" only as an operational ratio. It is not a claim
that all primary reasoning was waste; the purpose is to identify whether
routine control-plane work scales with child phase count.

## Integration principles

- Reuse `project_id`, `queue_id`, `entry_id`, `chain_id`, parent dispatch ids,
  and attempt ids instead of inventing path/name heuristics.
- Build on #54 for context pressure semantics.
- Preserve separate raw rows for each generation and child attempt; aggregate
  only in queries/materialized reports.
- Avoid double-counting a primary that is itself Harnex-managed.
- Keep plain-text `koder/` artifacts canonical; telemetry is evidence, not
  project memory.
- Make session rotation observable but do not make telemetry responsible for
  deciding or performing rotation.

## Acceptance criteria

- [x] A stable orchestration run id links multiple primary-session generations
      and their child Harnex dispatches.
- [x] A Harnex-managed primary can be represented without synthetic duplicate
      usage rows.
- [x] An explicit external-primary ingestion path exists and is opt-in.
- [x] A Pi integration can emit bounded context/usage samples without exposing
      message or tool content.
- [x] Rotation/compaction/recovery lifecycle events preserve generation
      boundaries and reasons.
- [x] One documented query or CLI command computes primary-versus-worker usage,
      peak context, accepted outcomes, and per-accepted-entry orchestration
      ratios.
- [x] Missing and unsupported providers/harnesses remain distinguishable from
      observed zero.
- [x] Tests cover one generation, multiple clean rotations, child retries/fixes,
      accepted-outcome deduplication, and absent primary telemetry.
- [x] Telemetry docs include privacy boundaries and explain that provider cost
      is approximate where available.

## Out of scope

- Capturing prompts, transcripts, hidden reasoning, or raw tool payloads.
- Perfect provider billing reconciliation.
- Automatically deciding when to rotate or compact.
- Implementing the durable queue conductor itself.
- Replacing `koder/` queues, issues, plans, reviews, or state files.
- Requiring unsupported Claude/Codex interactive clients to fabricate usage.

## Relationship to existing work

- #43 measures attempt-level throughput and retry/fallback economics for Harnex
  dispatches; it explicitly leaves non-Harnex interactive-session capture out of
  scope.
- #47 provides queue attribution and parent linkage for joining child work.
- #52 provides typed acceptance/validation evidence for deduplicated outcomes.
- #54 adds active context-window pressure for structured Harnex sessions.
- #42 recovers durable app-server orchestrators but does not measure context
  growth or logical generations across fresh-session rotation.

## Triage

- **Tier**: A/B design track; split implementation into producer, storage/join,
  and rollup slices after the contract converges.
- **Risk**: medium/high because identity and aggregation mistakes can silently
  double-count usage.
- **First useful slice**: Pi-only external-primary samples plus an offline
  queue-run rollup, with unsupported status for every other harness.

## Resolution - 2026-07-15

Implemented the first production slice:

- `harnex run` accepts opt-in orchestration metadata flags and emits a
  top-level `orchestration` block when present, so child dispatches and
  Harnex-managed primaries can join to one logical `run_id` and generation.
- `harnex orchestration sample` appends bounded
  `harnex.orchestrator_sample.v1` JSONL rows for external interactive
  primaries. The sample schema stores ids, lifecycle event names, aggregate
  usage/context counters, tool-call counts, compactions, and rotation reasons
  only; no prompts, transcripts, tool arguments/results, secrets, or private
  payloads.
- `harnex orchestration report` computes `harnex.orchestration_tax.v1` rollups
  from dispatch summaries plus optional external samples: primary usage/cost,
  worker usage/cost, primary peak context by generation, tool calls,
  compactions, accepted/rejected/blocked/unknown child outcomes deduplicated by
  work id, primary usage/tool-calls per accepted entry, wall-time totals, and
  explicit `missing` / `unsupported` coverage.

The implementation does not install global hooks into Pi or any other client.
A Pi extension or queue conductor can opt in by calling
`harnex orchestration sample` with bounded counters.
