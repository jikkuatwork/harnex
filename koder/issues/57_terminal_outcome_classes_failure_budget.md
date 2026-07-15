---
status: open
priority: P1
issue_kind: slice
created: 2026-07-15
updated: 2026-07-15
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

- [ ] Every dispatch row carries exactly one `outcome.class` with a documented
      closed vocabulary and an `unknown` fallback.
- [ ] Zero-token/no-activity completions are distinguishable from crashes,
      timeouts, completed artifacts with a missing report, and schema-invalid
      reports.
- [ ] "Terminal state disconnected but typed report ingested" classifies as
      completed-with-proof, not as a reliability failure (see #47's
      generic-disconnection complaint).
- [ ] One command aggregates outcome classes across a queue/run id and
      evaluates an optional caller-declared failure budget.
- [ ] Rollups report both raw failed attempts and retry/failure families joined
      by parent attempt/dispatch identity, so correlated retries do not look
      like unrelated root causes.
- [ ] Budget evaluation can name which outcome classes count as fatal; a caller
      can separate no-work/boot failures from reconstructable proof warnings.
- [ ] Reclassification is not required for historical rows; the contract is
      additive.
- [ ] Tests cover each class plus the budget breach and non-breach paths.

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
