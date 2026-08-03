# Plan 34 Staged RED Correction Review

Verdict: pass

Review target: commit `96ab94f` with accidental `koder/STATE.md` edit
mechanically reverted by `4161500`.

Scope read:

1. `koder/reviews/34_telemetry_canonical_reconciliation_red.md`
2. `koder/plans/34_telemetry_canonical_reconciliation.md`
3. `koder/issues/67_telemetry_canonical_reconciliation.md`
4. `git show 96ab94f -- koder/plans/34_telemetry_canonical_reconciliation.md koder/issues/67_telemetry_canonical_reconciliation.md`

I did not run tests or inspect implementation source, per brief. Preflight
showed `main...origin/main` with only `.harnex/dispatch.jsonl` modified before
this review file was created.

## Finding Closure

The amendment correctly changes Plan 34 from one overloaded RED suite into a
minimal staged contract:

- RED-0 is explicitly the already-observed missing route/help behavior from
  `b38a143`, with `11 runs, 29 assertions, 11 failures, 0 errors`, and the RED
  review reason preserved: every contract was hidden behind the same absent
  `telemetry` command seam.
- GREEN-0 is limited to routing/help, approved subcommand and option parsing,
  path/option resolution, and one bounded versioned report shell with
  `status: not_implemented` plus nonzero executable exits.
- GREEN-0 explicitly forbids canonical/source reads, directory scanning,
  identity analysis, appends, and all writes, which keeps it from absorbing the
  real reconciliation implementation.
- Focused GREEN-0 proof is named: help text, unknown subcommand, unknown
  option, `--canonical`/`--global` conflict, missing `reconcile --source`, JSON
  report schema/status, nonzero exits, and byte-identical fixtures.
- RED-1 requires rerunning the full telemetry file after GREEN-0 and must
  produce multiple named behavioral assertion failures with `0 errors`, no
  longer a top-level unknown-command failure.
- RED-1 also requires a fresh RED review before scanner or mutation code lands.
- GREEN-1 retains all actual canonical/source reads, classification, identity
  comparison, real reports, and locked append behavior.

Prior RED P1-1 is closed for planning. The amendment carries the missing v2
identity discriminator into RED-1 as a concrete required assertion: two valid
v2 start/end pairs share one `session_id` while differing in `id` and/or
normalized `started_at`, and `assert-canonical --json` must be clean with
counts proving both pairs survived independently. That directly covers the
reviewed gap where a bad implementation could key v2 rows by `session_id`
alone.

Prior RED P2-1 is closed for planning. The amendment requires canonical
exclusion and symlink pruning to be observable with distinct would-be source
candidates, not hidden behind already-present canonical rows or duplicate
candidate collapse. That preserves the original directory-discovery concern
without deferring it silently.

Prior RED P3-1 is closed for planning. Unknown telemetry option handling is
now explicitly pinned through GREEN-0/RED-1 under the same parse-error
convention as other commands.

The issue amendment is consistent with the plan amendment: it changes TDD from
unstaged strict RED/GREEN to staged strict RED/GREEN, names the skeleton as a
route/parser/report step, and keeps scanner/assert/reconcile behavior after
the behavioral RED stage. It does not weaken the safety contract or acceptance
criteria.

## Findings

No numbered findings.

## Sign-Off

`staged RED correction`: pass.

The P1/P2/P3 findings from the prior RED review are not dropped or moved out of
scope; they are converted into explicit RED-1 obligations after a deliberately
thin GREEN-0 seam commit.
