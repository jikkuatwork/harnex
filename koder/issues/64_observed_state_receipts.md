---
status: resolved
priority: P2
issue_kind: slice
created: 2026-08-02
updated: 2026-08-03
tags: artifact-report, receipts, proof, completion, queue
---

# Issue 64 — Generate phase receipts from observed state, not model-authored JSON

## Problem

Proof-of-work currently depends on the worker model authoring a
`harnex.artifact_report.v1` JSON file, which harnex then ingests, fingerprints
for freshness (`lib/harnex/runtime/session.rb:721-727`,
`lib/harnex/artifact_report.rb:205-219`), validates, and coordinators
re-validate and reconcile. This creates an ambiguity class where work is done
but proof reads as missing/stale (see #61, #36, and Holm Q096: three
"missing durable proof" verdicts against phases that had accepted reports —
Holm `koder/plans/708_S00_process_mechanization_mapping/INDEX.md`). It also
costs ~130+ lines of model-generated JSON per phase (Holm Q096-01: 937 lines
of receipts for a 6-line product change) and burns worker tokens on
formatting instead of work.

Harnex already observes nearly everything the receipt claims: start/end SHA,
diff stat, changed paths, commits, command executions and exit codes, token
usage, turn outcome (`actual`/`outcome` builders,
`lib/harnex/runtime/session.rb:1797-1853`, `:1661-1690`).

## Goal

1. Harnex generates the canonical phase receipt at completion from observed
   facts: git delta (start↔end SHA, files, LOC), commands executed with exit
   codes, turn outcome, usage. Written alongside the dispatch end row (#63)
   or as the report file — but authored by the harness.
2. The worker may attach a small optional claims block (summary, verdict,
   findings); claims never determine receipt validity.
3. `artifact-report validate --final` semantics preserved for consumers, now
   over harness-authored content; freshness fingerprinting becomes internal
   bookkeeping, not an acceptance gate a coordinator can trip over.
4. `completed_no_activity` (#60) keeps working: the observed-state receipt is
   precisely the evidence that classification needs.

## Acceptance Criteria

- A completed dispatch yields a valid final receipt with zero model-authored
  JSON required; a review-phase dispatch can attach a claims block (verdict,
  P1/P2/P3 counts) that shows up in the receipt.
- The "accepted report treated as missing durable proof" scenario from Holm
  Q096 is unreproducible: proof exists from the moment the harness observes
  completion.
- Receipt content is sufficient for a queue runner (#59) to gate
  commit-proof and no-change outcomes without reading transcripts.

## Resolution

Implemented on 2026-08-03 for the post-0.9.0 worktree:

- Every dispatch now atomically writes a harness-authored
  `harnex.artifact_report.v1` receipt to a default retained state-directory
  path (or an explicit `--artifact-report` override). Structured completion
  writes proof before publishing `task_complete`, then teardown refreshes usage
  and Git evidence.
- Receipts include harness provenance, start/end SHA, committed and
  uncommitted changed paths/LOC, commit count, bounded Codex command exits,
  turn acceptance, and usage. Starting worktree state prevents unchanged
  pre-existing dirt from appearing as worker activity; Harnex-owned telemetry
  and receipt paths are excluded.
- `HARNEX_ARTIFACT_CLAIMS_PATH` accepts only bounded advisory summary, verdict,
  and P1/P2/P3 counts. Claims and legacy worker reports cannot determine
  acceptance; malformed/stale input is ignored and the final file is replaced.
- `artifact-report validate --final` recognizes harness receipts while retaining
  legacy v1 validation. `--require-artifact-report` and `init` remain compatible
  but are no longer required for ordinary dispatch proof.
- Receipt/claims files are covered by 45-day / 1-GiB configurable retention and
  protected while their session is live.

Verification: focused artifact/session/runner/Git/retention tests plus the full
suite pass at 648 runs, 2,808 assertions, 0 failures/errors, and 2
environment-gated skips. A disposable CLI smoke also generated a default
receipt for an uncommitted product change and passed `validate --final`.
