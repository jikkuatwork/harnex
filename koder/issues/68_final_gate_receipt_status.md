---
status: resolved
priority: P3
issue_kind: slice
created: 2026-08-08
updated: 2026-10-18
tags: telemetry, receipts, validation, dispatch
---

# Issue 68 — Separate final-gate status from command-history failures

## Problem

Receipts conflate exploratory/intermediate command failures with final
acceptance status. In Holm's Q108 drain (2026-08-08), two accepted phases
retained `validation: fail` although every declared final acceptance command
passed — one worker ran an exploratory `rg` against nonexistent paths, another
had an intermediate test failure before the final gates went green. The
supervisor resolved both by verbatim replay, but the receipt field is noise:
`validation` currently reports command *history*, not final *acceptance*.

Source: Holm Analysis `803` §8 ("Harnex validation status is noisy") and Holm
Issue `#618` D3 (adopted, harnex-owned, non-blocking for Holm's Q109).
Precedent shape: #57 outcome classes, #59 runner primitives.

## Proposal

1. Dispatches may declare final-gate commands (repeatable
   `--final-gate '<cmd>'` or an equivalent meta field).
2. Receipts/summaries expose two separate fields:
   - `commands_had_failures: bool` — any nonzero exit anywhere in the
     session's command history (harness-observed);
   - `final_gates: {declared: N, observed_pass: N, status: pass|fail|undeclared}`
     — matched by exact command string, exits observed by the harness, never
     taken from worker prose.
3. When final gates are declared, the top-level `validation` field reports
   final-gate status; the legacy any-failure-means-fail behavior applies only
   when undeclared (backward compatible).

## Acceptance

- History = [exploratory command fails, all declared finals pass] ⇒
  `validation: pass`, `commands_had_failures: true`.
- History = [any declared final fails] ⇒ `validation: fail`.
- No declared finals ⇒ current semantics unchanged, `final_gates.status:
  undeclared`.

## Bounds

- This must not weaken proof: consumers (e.g. Holm's queue workflow) keep
  supervisor verbatim replay of declared final commands as the acceptance
  proof; this issue is receipt ergonomics/diagnostics only.
- Exact-string matching only; no fuzzy command matching in v1.

## Resolution

Implemented 2026-10-18 as proposed, with these concrete choices:

- `harnex run --final-gate '<cmd>'` (repeatable) appends to meta
  `final_gates`; meta is the single transport, so tmux/detached children and
  dispatch rows carry the gates. At most 20 gates.
- Receipt `validation` gains `commands_had_failures` (tracked by the session
  across the whole history, not the 50-command window) and `final_gates`
  `{declared, observed_pass, observed_fail, missing, status, gates[]}`.
- Each gate is decided by its last observed run. Matching is exact after
  unwrapping a single `bash -lc`/`sh -c`-style transport wrapper (not fuzzy).
- A never-observed gate is `fail` under complete observation and `unknown`
  under `partial`/`unsupported` observation; status therefore extends the
  proposal's enum with `unknown`.
- Acceptance unchanged: `validate --final`, outcome classes and supervisor
  replay are untouched. Undeclared ⇒ legacy semantics, `status: undeclared`.

Tests: receipt unit tests in `test/harnex/artifact_report_test.rb`, Pi session
tests in `test/harnex/runtime/session_pi_rpc_test.rb` (including a failure
outside the retained window), and run flag parsing in
`test/harnex/commands/run_test.rb`. Docs: `docs/dispatch-telemetry.md`.
