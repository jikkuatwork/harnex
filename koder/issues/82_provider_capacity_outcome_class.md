---
status: resolved
priority: P2
created: 2026-10-20
updated: 2026-10-20
tags: outcomes, pi, retry, orchestration
issue_kind: slice
type: feature
related: 57, 62, 81
---

# Issue 82 — A `provider_capacity` outcome class, with optional automatic retry

Foundry-backed pi turns sometimes fail after pi's own retries with "high demand … exceeds the
maximum usage size allowed during peak load" (Holm Queue 159, 2026-10-18/19; seen several
times). Harnex reports this as a generic `task_failed`: `OUTCOME_CLASSES` in
`lib/harnex/runtime/session.rb` has no capacity class. The text is only in status JSON
`last_error` and in the wait result, so every supervisor has to string-match it.

Want: classify pi provider-capacity and rate-limit errors as `provider_capacity` (in status
JSON, dispatch rows and `orchestration report --failure-budget`). Optionally add
`harnex run ... --retry-on capacity N [--fallback-model M]`: on that class, relaunch the same
context up to N times in the same `--cwd`, linking attempts with the #62 retry fields
(`--attempt-kind retry --parent-dispatch-id`), and move to M after the first retry. Holm's
manual rule today: nudge once, relaunch on the fallback model, then on lower thinking, and park
after three failed launches.

## Decisions (owner, 2026-10-20) — ready for autonomous implementation

- **Class only.** Add `provider_capacity` to the outcome vocabulary, set from
  Pi's structured retries-exhausted signal (`auto_retry_end success:false`
  with `finalError`), never from transcript text. Surface it in status JSON,
  dispatch rows and `orchestration report --failure-budget`.
- **Deferred:** `run --retry-on capacity N [--fallback-model M]` belongs to the
  #59 conveyor runner.

## Resolution

Shipped in 0.18.0 (local install): `provider_capacity` from Pi's
`auto_retry_end success:false`, fatal by default in `--failure-budget`.
Hermetic tests only; a real capacity failure was not reproduced live.
`--retry-on` stays deferred to #59.
