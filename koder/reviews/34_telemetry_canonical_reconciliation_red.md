# Plan 34 RED Contract Review

Verdict: needs_fixes

Review target: commit `b38a143` as the executable RED contract for Plan 34 /
Issue 67.

Scope read:

1. `koder/plans/34_telemetry_canonical_reconciliation.md`
2. `koder/issues/67_telemetry_canonical_reconciliation.md`
3. `koder/reviews/34_telemetry_canonical_reconciliation.md`
4. `koder/reviews/34_telemetry_canonical_reconciliation_rereview.md`
5. `test/harnex/telemetry_reconciler_test.rb`
6. `lib/harnex/cli.rb`
7. `lib/harnex/dispatch_history.rb`

I did not run tests, per brief. Supervisor observed the new test file REDs with
`11 runs, 29 assertions, 11 failures, 0 errors, 0 skips`.

## Coverage Table

| Approved Plan 34 behavior | Test coverage | Assessment |
| --- | --- | --- |
| Clean mixed-era canonical stream passes, including v2 start/end, thin v1, envelope-less rich, and legacy unknown | `test_assert_canonical_accepts_clean_mixed_era_stream` | Covered. |
| Malformed canonical JSON fails | `test_assert_canonical_rejects_malformed_canonical_json` | Covered. |
| Duplicate v2 start/end identity fails | `test_assert_canonical_enforces_v2_identity_pairing_and_allows_open_starts` | Covered for exact duplicate payloads. |
| v2 end with no/mismatched start fails; unpaired start passes | `test_assert_canonical_enforces_v2_identity_pairing_and_allows_open_starts` | Covered. |
| v2 identity is `(session_id, id, normalized started_at UTC instant)`, not `session_id` alone | Same test name claims v2 identity coverage | Not covered; see P1-1. |
| Source rich row absent from canonical makes assert and dry-run reconcile fail without write | `test_source_drift_fails_assert_and_reconcile_dry_run_without_writing` | Covered. |
| Apply appends one row and second apply is byte-identical no-op | `test_reconcile_apply_appends_missing_once_and_rerun_is_byte_identical` | Covered. |
| Identity conflict blocks whole batch and leaves canonical bytes unchanged | `test_identity_conflict_blocks_full_batch_without_writing` | Covered. |
| Equivalent ISO offsets deduplicate legacy identity without rewriting payload text | `test_equivalent_iso_offsets_deduplicate_legacy_identity` | Covered. |
| Directory source excludes canonical, `.git`, symlinks, and ignores unrelated JSON | `test_directory_sources_exclude_canonical_git_and_symlinks` | Partly covered; see P2-1. |
| Generic JSON with `meta.id`, `meta.started_at`, and `actual` but without rich harnex sections is ignored | `test_source_classifier_ignores_unrelated_json_but_fails_malformed_declared_telemetry` | Covered. |
| Explicit malformed source telemetry fails | `test_source_classifier_ignores_unrelated_json_but_fails_malformed_declared_telemetry` | Covered for explicit file input. |
| JSON report is stable, bounded, and payload-free | `REPORT_KEYS` and `test_json_report_is_bounded_and_never_echoes_payloads` | Covered for key set, diagnostic cap, and marker redaction. |
| CLI help, unknown subcommand, option conflict, and required source errors follow conventions | `test_cli_help_unknown_subcommand_option_conflict_and_required_source_contract` | Covered for the listed cases. |

## RED Reason Assessment

The suite invokes the real CLI path through `RbConfig.ruby`, `bin/harnex`, and
the `telemetry` namespace in `telemetry` at
`test/harnex/telemetry_reconciler_test.rb:249`. There are no source-text checks
and no test-local production substitutes.

The current production router has no `telemetry` command in
`lib/harnex/cli.rb`, so the observed all-failure RED reason is expected. This
is acceptable only if each test will independently exercise a distinct
contract once routing exists.

Most tests satisfy that bar: they construct distinct canonical/source fixtures
and assert distinct report fields, statuses, diagnostics, byte-identity checks,
or CLI stderr contracts. The shared `assert_report` helper does not make the
suite tautological by itself because callers pin different command/status/count
combinations.

The RED contract is still not executable-thin enough to pass because the v2
identity regression that drove the prior P1 correction is not independently
pinned. An implementation that keys v2 rows only by `session_id` can avoid every
current v2 fixture and still satisfy the test suite.

## Findings

### P1-1. Missing executable pin for corrected v2 identity discriminator

Plan 34 now requires one start and one end per `(session_id, id, normalized
started_at UTC instant)` and states that `session_id` is an additional
discriminator, not a substitute for dispatch ID and start instant
(`koder/plans/34_telemetry_canonical_reconciliation.md:84` and
`koder/plans/34_telemetry_canonical_reconciliation.md:113`). This was the
prior plan review's P1 finding and the rereview's main closure point.

The RED test named as v2 identity coverage builds only three v2 shapes:

- one open start with one `session_id`;
- exact duplicate starts and ends sharing the same `session_id`, `id`, and
  `started_at`;
- one start and one end with the same `id`/`started_at` but different
  `session_id`.

That is useful pairing and duplicate coverage, but it never creates two valid
dispatches that intentionally reuse the same `session_id` with different
`id` and/or normalized `started_at` values. A bad reconciler that indexes v2
state by `session_id` alone would not be caught by
`test/harnex/telemetry_reconciler_test.rb:64`.

Required fix: add a RED assertion, preferably in the existing v2 test, where
two complete v2 start/end pairs share a `session_id` but have different
`id`/`started_at` identities and `assert-canonical --json` must return clean
with `families.v2_start == 2` and `families.v2_end == 2` or another explicit
count that proves both pairs survived independently.

### P2-1. Directory exclusion test does not prove canonical and symlink pruning

Plan 34 requires directory scans to exclude the resolved canonical path, prune
`.git`, and avoid symlink traversal
(`koder/plans/34_telemetry_canonical_reconciliation.md:131`). The test at
`test/harnex/telemetry_reconciler_test.rb:170` catches `.git` inclusion because
`cx-git-ignored` would increase `missing`, but the canonical and symlink parts
are weaker.

Scanning the canonical file as a source would merely find the already-present
`cx-present` row, so the asserted `missing: 1` still passes. Following the
symlink to `missing.jsonl` can also still produce `missing: 1` if candidate
deduplication or identity collapsing removes the duplicate. The test title
claims all three exclusions, but only one is meaningfully observable.

Recommended fix: make the canonical path contain a row that would be counted as
a source candidate only if canonical exclusion is broken, and make the symlink
point at a distinct missing rich row. Then assert counts/diagnostics show only
the intended regular source file was scanned.

### P3-1. Unknown-option error is not separately pinned

Phase 2 asks for CLI help, unknown subcommand, and option errors. The current
CLI test covers help, an unknown subcommand, `--canonical`/`--global` conflict,
and missing `--source` for `reconcile`
(`test/harnex/telemetry_reconciler_test.rb:227`). That is enough for the core
parse contract, but it does not prove an actually unknown telemetry option uses
the existing parse-error convention.

This is not blocking if the P1/P2 gaps are fixed, but adding one
`--definitely-unknown` assertion would make the option-error pin complete.

## Sign-Off

`RED contract executable`: reject.

Thinness for this single capability: needs_fixes. The suite is close and mostly
behavioral, but it omits the corrected v2 identity discriminator that Plan 34
explicitly elevated after review.
