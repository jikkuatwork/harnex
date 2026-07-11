---
status: partial
issues: [43, 46]
plan: 31
tier: B
layer: telemetry-v2-foundation
created: 2026-07-11
phases: 5
---

# Plan 31 — Usage provenance, attribution, and outcomes (#43, #46)

## Goal

Close the currently documented telemetry gaps without replacing either existing
JSONL writer or breaking consumers of the established `meta`, `actual`,
`agent`, `queue`, and `reliability` fields. The work is one layer with two
issues: **#46** supplies trustworthy raw-usage semantics, while **#43** adds
attribution, work outcome, and one-attempt lifecycle records that let consumers
join and group those raw measurements safely.

## Locked decisions

1. **The existing summary row remains canonical.** New data is top-level,
   additive blocks; no second writer and no migration of historical records.
2. **`actual.*` remains compatibility data.** `usage` explains whether its
   nullable token/cost values were observed, estimated, unavailable because an
   adapter does not support telemetry, or explicitly zero.
3. **An attempt is one Harnex session.** `attempt.id` is Harnex's random
   per-session `session_id`; `attempt.run_id` is the operator-visible session
   `id`. A caller may link an independent retry/fix/review session with
   `parent_attempt_id` and the existing `parent_dispatch_id`.
4. **Harnex never infers semantic acceptance from a diff.** Git observations
   provide commit/path/LOC evidence. `outcome.status=accepted|rejected` is only
   recorded from the bounded worker sidecar; absent proof remains `unknown` or
   `no_change` when there is definitively no git change.
5. **No fake fallback/retry counts.** The base contract emits lifecycle events
   for the single session attempt and recognises adapter retry notifications.
   It exposes zero/false fallback fields until #42/plan 30 create real
   cross-process recovery/fallback attempts.

## Progress — 2026-07-11

Phases 1–3 and the contract/docs portion of Phase 5 are implemented and
verified by the full suite (517 runs, 1912 assertions, 0 failures, 2 skips).
#46 is closed as implemented/unreleased. Phase 4's public transition seam is
implemented, but its live recovery/fallback producer remains correctly owned by
#42 and plan 30; therefore #43 remains open rather than claiming fabricated
fallback economics.

## Phase 1 — #46 usage-provenance schema

- Add top-level `usage` with stable keys: `status`, `cost_usd`, `cost_source`,
  `input_tokens`, `output_tokens`, `cached_input_tokens`, `reasoning_tokens`,
  and `total_tokens`.
- Define status precedence: explicit bounded estimate metadata, an observed
  adapter measurement (including true zero), adapter unsupported, then missing.
- Add `usage.status` plus cost-source semantics to dispatch telemetry docs.
- Tests: observed Pi-style use, observed zero, caller estimate, unsupported
  generic adapter, and a telemetry-capable adapter that yields no observation.

## Phase 2 — #43 attribution and outcome evidence

- Add top-level `attribution` (`status`, project/phase/intent/work-id quality)
  derived exclusively from the caller's first-class metadata.
- Extend the bounded artifact report v1 payload with optional outcome proof:
  `accepted`, `rejected`, `no_change`, or `unknown`. Preserve old valid reports.
- Capture changed paths in the existing final git capture and add a top-level
  `outcome` block with sidecar-proven status, end commit SHA, changed paths, and
  LOC measurements. Document that git evidence is not authorship proof.
- Tests: complete/partial/missing attribution; accepted sidecar outcome;
  deterministic no-change outcome; bounded changed paths.

## Phase 3 — Attempt identity and lifecycle

- Add `--parent-attempt-id` and `--attempt-kind` (`initial`, `retry`, `fix`,
  `review`, `superseding`) as first-class telemetry fields, forwarded through
  tmux re-exec.
- Add top-level `attempt` and terminal-summary actual counters for the one
  logical session: total/succeeded/failed/retry/429/disconnect plus wall-clock
  throughput values only when the denominator and accepted-work condition are
  known.
- Emit additive `attempt_started` and `attempt_finished` events. Translate
  structured `auto_retry_start/end` notifications into a retry-scheduled event
  without claiming a new Harnex attempt.
- Tests: linked two-dispatch fixture has independent effort/usage rows and one
  accepted outcome; retry and disconnect event/counter behaviour.

## Phase 4 — Recovery/fallback integration seam

- Supply a Session-owned `record_attempt_transition` seam for the #42 recovery
  and plan-30 fallback machinery to emit `attempt_retry_scheduled` and
  `attempt_fallback_switched` with an immutable parent attempt ID and a new
  child ID.
- Until those features are enabled, summaries explicitly report zero retries
  and `fallback_triggered: false`; no test or documentation claims runtime
  fallback exists.
- Add deterministic unit coverage for the transition payload and counter
  aggregation. A real fallback integration remains owned by plan 30's final
  phase, not fabricated in this telemetry-only change.

## Phase 5 — Documentation, query examples, and verification

- Document every new block, stable statuses, and the distinction between
  provider-reported/estimated/missing cost.
- Add `jq` examples for successes/hour, retry tax, reliability rate, and
  grouping by complete attribution + effective model.
- Run focused telemetry tests followed by the full project suite. Close #46
  after Phase 1 and #43 only after its implemented acceptance criteria are
  verified; leave #42/plan-30 execution work explicitly linked rather than
  falsely calling it telemetry coverage.

## Risks and guards

- **Null mistaken for zero:** explicit `usage.status` and nullable numeric
  fields prevent it.
- **Semantic authorship overclaim:** outcome acceptance requires sidecar proof;
  diffs remain observations.
- **Duplicate accounting:** each session has one `attempt.id`; linked work keeps
  raw rows distinct and outcome aggregation selects accepted outcomes.
- **Schema breakage:** all additions are top-level/additive; schema regression
  tests retain legacy blocks and fields.
