# Plan 34 RED-1 Repair Rereview

Verdict: pass

Review target: test-fix commit `526390c` (`test: repair telemetry RED-1
contract`).

Scope read:

1. `koder/reviews/34_telemetry_canonical_reconciliation_red1.md`
2. `git show 526390c`
3. `test/harnex/telemetry_reconciler_test.rb`
4. `koder/plans/34_telemetry_canonical_reconciliation.md`

I did not rerun tests, per rereview brief. Supervisor proof after `526390c`
says:

- shell pin: `1 run / 10 assertions / 0 failures`;
- telemetry RED-1: `11 runs / 37 assertions / 10 failures / 0 errors`;
- baseline excluding telemetry: `658 runs / 2836 assertions / 0 failures /
  0 errors / 2 skips`.

## Closure

1. Corrected v2 identity is now executable.

`test_assert_canonical_enforces_v2_identity_pairing_and_allows_open_starts`
adds `same-session.jsonl` with two complete v2 start/end pairs sharing
`session_id: "sess-shared"` while differing by dispatch ID and normalized start
instant. The assertion requires `canonical_rows: 4`, two v2 starts, two v2 ends,
and `open_starts: 0`, so an implementation keyed by `session_id` alone cannot
satisfy the clean report.

2. Canonical and symlink directory pruning are now observable.

`test_directory_sources_exclude_canonical_git_and_symlinks` now points the
symlink at a distinct target row (`cx-linked-ignored`) and asserts
`sources.files_scanned == 2`, `sources.candidates == 1`, `present == 0`, and
`missing == 1`. Those counts make scanning the canonical path, following the
symlink, or scanning `.git` produce a visible report mismatch instead of being
masked by identity dedupe.

3. Explicit file versus directory malformed classification is now covered.

`test_source_classifier_ignores_unrelated_json_but_fails_malformed_declared_telemetry`
splits the clean unrelated JSON directory from a directory-discovered
`mixed.jsonl` containing one recoverable rich row plus malformed sibling
content. It separately asserts the directory-discovered malformed telemetry and
the explicit malformed file are fatal, while the generic summary-only directory
is clean.

4. Bounded-report truncation is no longer tautological.

`test_json_report_is_bounded_and_never_echoes_payloads` now creates 55 missing
rich records with marker secrets. It asserts `missing: 55`, diagnostics capped
at 50, and `diagnostics_truncated >= 1`, while retaining the stdout/stderr
payload-marker refutations.

5. Unknown telemetry option handling is pinned in the full behavioral file.

`test_cli_help_unknown_subcommand_option_conflict_and_required_source_contract`
now invokes `assert-canonical --definitely-unknown` and requires exit 2 with
both `invalid option` and the option spelling in stderr.

## Contract Verdict

RED contract executable: pass. The repaired test file now owns the named
Plan 34 RED-1 behaviors through CLI subprocesses, and supervisor counts show
multiple behavioral failures with `0 errors` rather than an unknown route or
fixture failure.

Coverage ownership: pass. The five prior gaps now have explicit assertions in
`test/harnex/telemetry_reconciler_test.rb`, while the existing tests continue
to own zero-write, idempotency, conflict, offset identity, report shape, and
CLI exit semantics.

Scope fidelity: pass. Commit `526390c` changes the telemetry test contract and
dispatch telemetry only; it does not add scanner, classifier, identity,
append, source-read, docs, changelog, plan, issue, or production behavior.

Staged thinness signoff: pass. The supervisor RED-1 count remains
`11 runs / 37 assertions / 10 failures / 0 errors`, so GREEN-0 stays a thin
route/parser/report shell and GREEN-1 remains responsible for the actual
reconciler implementation.

Bounded claims verdict: pass. This rereview relies on the command-proven
counts above and the targeted `526390c` diff only; no broader implementation
claim is made.
