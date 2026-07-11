---
status: open
priority: P1
---

# Issue 43 — Throughput-first telemetry v2 (attempt-level + retry/fallback economics)

**Status**: open
**Priority**: P1
**Filed**: 2026-05-19
**Tier**: B (plan -> impl -> verification)
**Sister**: extends #23 (dispatch telemetry), #35 (telemetry hygiene), #40 (fallback), #42 (app-server recovery).

## Problem

Current harnex telemetry is good for basic run accounting, but not yet strong enough for
**throughput-first operations**. We still lack clean, machine-readable answers to:

1. How much useful work/hour did we get per model/deployment?
2. What share of time/tokens was lost to retry/disconnect/throttle tax?
3. Did fallback/recovery improve throughput or just move cost around?
4. Which runs are unattributed (missing project/phase/intent), making routing analysis noisy?

Without these signals, we tune routing from partial visibility.

## Observed implementation gap — 2026-07-11

The current write path is Harnex-owned and already emits two related JSONL
surfaces:

- `Harnex::DispatchHistory` appends a compact terminal row to the repo-local
  `.harnex/dispatch.jsonl` (or the global state path outside a git repo).
- `Harnex::Session#build_summary_record` writes the structured terminal summary
  containing `meta`, `predicted`, `actual`, `agent`, `queue`, `validation`, and
  `reliability` blocks. The Codex/Pi adapters feed model and usage observations
  into the session before finalization.

The current contract identifies the requested/effective model and records some
provider-specific usage, but it cannot yet answer durable work-attribution
questions reliably:

- which model produced the surviving commit or changed paths;
- changed files/LOC and test outcomes attributable to the dispatch;
- token/cost totals when the adapter did not expose them, versus genuinely zero
  usage;
- whether a retry/fix/re-review superseded the earlier work or merely added
  more effort to the same slice;
- whether a top-level queue result was accepted, rejected, or still pending.

The existing run-level row is therefore a useful accounting record, but not yet
a complete model-effectiveness record. This issue should extend the existing
contract rather than introduce a second telemetry writer or ask downstream
orchestrators to infer authorship from free-form summaries and git history.

## Implementation status — 2026-07-11

Plan 31 implemented the telemetry-contract foundation: additive `usage`,
`attribution`, `outcome`, and per-session `attempt` summary blocks; stable
parent-attempt/parent-dispatch flags; changed-path/LOC observations; bounded
sidecar-backed accepted/rejected outcomes; lifecycle events; Pi retry event
translation; and a Session transition seam for future recovery/fallback owners.
All of this is schema-tested and backward-compatible.

This issue remains open only for runtime work owned by #42 and plan 30: a real
recovery/fallback implementation must invoke the transition seam so a live
integration test can measure pre/post economics and retry waste. Harnex does
not fabricate fallback telemetry before such a path exists.

## Goal

Add telemetry that makes throughput optimization first-class:

- accepted work per wall-clock hour
- retry/throttle/disconnect tax
- pre/post fallback effectiveness
- strict attribution by project + phase + intent

Default behavior should remain backward-compatible for existing users.

## Proposed telemetry additions

### 1) Attempt-level lifecycle events (not just run-level)

Add structured events for each run attempt:

- `attempt_started`
- `attempt_finished`
- `attempt_retry_scheduled`
- `attempt_fallback_switched` (when applicable)

Required fields:

- `run_id`, `attempt_id`, `parent_attempt_id` (nullable)
- `project`, `phase`, `intent`
- `model_requested`, `model_effective`, `deployment_effective`
- `reasoning_effort`, `service_tier`
- `start_ts`, `end_ts`, `wall_ms`
- `exit_reason` (`success`, `429`, `disconnect`, `timeout`, `error`, ...)

### 2) Attribution guardrails

Support strict attribution mode (config/flag):

- required: `project`, `phase`, `intent`
- if missing: fail-fast (strict mode) OR emit `attribution_missing` warning event (default mode)

### 3) Token and waste accounting per attempt

Capture counters per attempt and aggregate to run summary:

- `input_tokens`, `output_tokens`, `cached_input_tokens`
- `reasoning_tokens` (when surfaced by adapter/provider)
- `tokens_wasted_retry` (attempts that failed before completion)
- `tokens_wasted_disconnect` (where identifiable)

### 4) Retry/fallback economics

When retry or fallback occurs, emit enough detail for post-hoc tradeoff analysis:

- `trigger` (`429_rate`, `disconnect_rate`, `stream_error`, manual)
- pre/post counters split (duration, tokens, success, retries)
- pre/post model/deployment labels

### 5) Throughput summary fields in dispatch row

Add additive summary fields to the dispatch row (or linked child rows if fallback split shape is used):

- `actual.attempts_total`
- `actual.attempts_succeeded`
- `actual.attempts_failed`
- `actual.retry_count`
- `actual.throttle_429_count`
- `actual.disconnect_count`
- `actual.throughput_tokens_per_s` (accepted)
- `actual.throughput_successes_per_h`
- `actual.retry_tax_pct`
- `actual.unattributed` (bool)

## Acceptance criteria

- New telemetry fields are emitted for codex app-server runs and schema-tested.
- Existing telemetry consumers do not break (additive schema; old fields preserved).
- At least one integration test covers: success run, retry path, disconnect path, and fallback path.
- `docs/dispatch-telemetry.md` documents all new fields + definitions.
- A small analysis script/query example can compute:
  - successes/hour
  - retry tax %
  - 429/disconnect rates
  - throughput by `project + phase + model_effective`
- Dispatch summaries expose explicit attribution-quality and outcome fields:
  - `attribution.status` (`complete`, `partial`, or `missing`)
  - `outcome.status` (`accepted`, `rejected`, `no_change`, or `unknown`)
  - `outcome.commit_sha` and changed-path/LOC measurements captured at
    finalization, without claiming that git changes prove semantic authorship
  - `usage.status` (`observed`, `unsupported`, or `missing`) so null usage is
    not confused with zero usage
- Retries, fixes, reviews, and superseding dispatches can be joined through
  stable parent/child IDs and summarized without double-counting accepted work.
- A fixture or integration test proves that two models contributing to one
  queue entry produce separate effort rows and one deduplicated accepted-work
  outcome.

## Out of scope (v1)

- Cross-provider canonical cost normalization.
- Perfect “business value delivered” scoring (only operational throughput here).
- Non-harnex interactive session capture (tracked separately; can be joined later).

## Triage

- **Tier**: B
- **Plan count**: 1
- **Estimated sessions**: 2–3
- **Estimated wall-clock**: ~4–6h

## Notes

This issue intentionally prioritizes **throughput observability** over cosmetic telemetry polish.
If we cannot reliably measure retry tax + accepted throughput, we cannot reliably optimize routing.
