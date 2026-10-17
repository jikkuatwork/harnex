---
status: resolved
priority: P1
issue_kind: slice
created: 2026-07-15
updated: 2026-10-18
tags: telemetry,outcomes,refusal,circuit-breaker,budget,queue
---

# Issue 57 — First-class terminal outcome classes and a run-scoped process-failure budget

## Problem

Dispatch rows record duration, usage, and reliability data, but the *terminal
outcome* of a dispatch is not classified. In SDK Queue `#002`
(`~/Projects/holmhq/sdk`,
`koder/analysis/001_q002_orchestration_efficiency/INDEX.md`) these outcomes all
looked alike in history and had to be reconstructed by a model from panes, Git,
and report files:

- two Pi fix dispatches ended "complete" with zero tokens, no report, and no
  commit (a refusal class, not a crash);
- several Codex attempts died at boot/registration/trust-prompt with no
  receipt;
- Claude workers completed real work while their terminal state read
  `disconnected`;
- 7 of 25 dispatches produced no proof of any kind.

Because outcome classes are invisible, circuit breaking lives in orchestrator
prose (koder-pattern's "two no-op attempts open a breaker") and every adapter,
config, or brief change silently resets the retry family. Queue `#002`
accumulated multiple two-attempt circuits across reconfigurations with no
global cap — the run had no machine-checkable notion of "this queue has burned
too many process failures; stop and return to the owner."

## Additional source incident — Holm Queue 086

Holm Queue `086` (2026-07-15) hit a manually declared six-failure budget even
though no product test failure caused the stop:

- two Codex app-server turns completed in 6-7s with zero commands, zero Git
  delta, and acknowledgment-only final answers;
- two review workers committed valid artifacts but wrote no sidecar, instead
  printing report-shaped JSON in final prose;
- one preflight and one implementation worker wrote syntactically valid but
  contract-invalid reports;
- the final implementation's targeted and package tests were green, but the
  flat counter treated all six events as equivalent and stopped before review.

This is three correlated failure classes, not six independent root causes.
Outcome rollups must preserve both attempt count and failure family, and callers
must be able to distinguish fatal no-work from reconstructable proof defects.
See #60 and #61.

## Progress

Harnex 0.7.14 implements the #60/#61 proof-acceptance subset: every new row has
additive `outcome.class` / `outcome.report_status`, with
`completed_with_proof`, `completed_with_activity`, `completed_no_activity`,
`report_missing`, `report_invalid`, `report_rejected`, `task_failed`, and
`unknown` classifications. Watch/wait/terminal marker payloads preserve these
proof failures. This does **not** close #57: boot/registration/permission/
timeout/disconnection classes, correlated-family rollups, and the run-scoped
budget command remain.

## Goal

1. An additive `outcome.class` on every dispatch row, from a small closed
   vocabulary, e.g.: `completed_with_proof`, `completed_no_receipt`,
   `zero_token_refusal`, `boot_failure`, `registration_timeout`,
   `permission_prompt`, `disconnected_unproven`, `stopped_by_caller`,
   `timeout`. Classification uses signals Harnex already has (usage totals,
   report ingestion, completion signal, exit path); it must not parse
   transcripts.
2. A rollup command (e.g. `harnex run-report --queue ID` or
   `--orchestration-run ID` once #55 lands) that counts outcomes by class
   across a queue/run and, given a declared budget (e.g.
   `--process-failure-budget 6`), prints a breach verdict with nonzero exit.

Enforcement (what to do on breach) stays with the caller/orchestrator; Harnex
supplies the ledger and the arithmetic.

## Acceptance criteria

- [x] Every dispatch row carries exactly one `outcome.class` with a documented
      closed vocabulary and an `unknown` fallback.
- [x] Zero-token/no-activity completions are distinguishable from crashes,
      timeouts, completed artifacts with a missing report, and schema-invalid
      reports.
- [x] "Terminal state disconnected but typed report ingested" classifies as
      completed-with-proof, not as a reliability failure (see #47's
      generic-disconnection complaint).
- [x] One command aggregates outcome classes across a queue/run id and
      evaluates an optional caller-declared failure budget.
- [x] Rollups report both raw failed attempts and retry/failure families joined
      by parent attempt/dispatch identity, so correlated retries do not look
      like unrelated root causes.
- [x] Budget evaluation can name which outcome classes count as fatal; a caller
      can separate no-work/boot failures from reconstructable proof warnings.
- [x] Reclassification is not required for historical rows; the contract is
      additive.
- [x] Tests cover each class plus the budget breach and non-breach paths.

## Out of scope

- Automatic retries, adapter switching, or breaker enforcement.
- Judging semantic quality of completed work (that is review, not telemetry).
- Provider-side refusal reason capture beyond what adapters already expose.

## Relationship to existing work

- Builds on plan-31 (#43/#46) usage/attribution/outcome blocks; this issue
  narrows "outcome" into a closed process-level taxonomy.
- #55 supplies run identity for the rollup; until then `--queue` suffices.
- #40 (disconnect-rate fallback) and #32 (early-boot rows) become consumers of
  the same classes instead of bespoke counters.
- #56 preflight failures should reuse this vocabulary.

## Triage

- **Tier**: B.
- **Risk**: medium — misclassification could hide real failures; keep the
  vocabulary small and default to `unknown` rather than guessing.
- **First useful slice**: classify from existing signals (usage totals, report
  ingestion, completion event, exit reason) plus the `run-report` count
  command; budget flag second.

## Resolution

Completed 2026-10-18 on top of the 0.7.14 proof classes.

- **Vocabulary** (`Session::OUTCOME_CLASSES`, closed, `unknown` fallback):
  completion `completed_with_proof`, `completed_with_activity`; proof defects
  `completed_no_activity` (the zero-token/no-work refusal shape),
  `report_missing` (completed without receipt), `report_invalid`,
  `report_rejected`; process `task_failed`, `boot_failure`,
  `permission_prompt`, `timeout`, `stopped_by_caller`, `process_failed`.
- **Classification** refines an `unknown`/`task_failed` terminal, or the
  receipt rejection of a process that never signalled completion
  (finalization always writes a receipt, so that rejection records the failed
  process), from the exit path, stop provenance (`StopRequest` reason + work
  state) and the final adapter input state. Completions and proof verdicts
  stand, so "disconnected but proof ingested" stays `completed_with_proof`. A
  stop/deadline outranks `task_failed` only when work was still running.
- **Not included:** `registration_timeout` (the session cannot observe the
  launcher giving up; #56 preflight reports it) and `disconnected_unproven`
  (a clean exit 0 without completion gets an accepted harness receipt under
  the existing #64 semantics, so the class could never be emitted; changing
  that acceptance rule is out of scope).
- **Rollup:** `harnex orchestration report (--run-id | --queue-id)` adds
  `workers.outcome_classes` (`attempts`, `families`, `family_count`); families
  join by `parent_attempt_id`, by `parent_dispatch_id` for non-initial
  attempts, or by a reused dispatch id. Start rows are not counted.
- **Budget:** `--failure-budget N [--budget-unit attempts|families]
  [--fatal-classes A,B]` → `failure_budget {limit, unit, fatal_classes,
  consumed, fatal_attempts, fatal_families, breached}`; exit 3 on breach
  (breached once consumed ≥ N). Default fatal classes: no-work and process
  failures; proof defects, caller stops and `unknown` are not fatal by
  default. Enforcement stays with the caller.

Tests: `test/harnex/runtime/session_outcome_class_test.rb`,
`test/harnex/orchestration_test.rb`. Docs: `docs/dispatch-telemetry.md`.
