# Plan 34 RED-1 Contract Review

Verdict: needs_fixes

Review target: current telemetry test suite after approved GREEN-0 skeleton
commit `067330b`.

Scope read:

1. `koder/plans/34_telemetry_canonical_reconciliation.md`
2. `koder/issues/67_telemetry_canonical_reconciliation.md`
3. `koder/reviews/34_telemetry_canonical_reconciliation_red.md`
4. `koder/reviews/34_telemetry_canonical_reconciliation_staged_red.md`
5. `test/harnex/telemetry_reconciler_test.rb`
6. `lib/harnex/commands/telemetry.rb`
7. `lib/harnex/dispatch_history.rb`

I did not run tests, per brief. Supervisor-independent proof says:

- focused shell contract: `1 run / 8 assertions / 0 failures`;
- full telemetry file: `11 runs / 35 assertions / 10 failures / 0 errors`;
- pre-existing non-telemetry tests: `658 runs / 2836 assertions / 0 failures /
  0 errors / 2 skips`.

## Coverage and RED Reason Table

| Plan 34 / RED-1 obligation | Current executable coverage | Assessment |
| --- | --- | --- |
| GREEN-0 route/parser/report skeleton is thin | `TelemetryCommand` parses approved subcommands/options and returns one `not_implemented` report; no canonical/source reads or writes are present | Covered. Staged thinness exception signed off. |
| RED failures reach named behavioral contracts instead of unknown top-level command | Supervisor proof shows `10 failures / 0 errors` after one focused shell pass | Covered in shape, subject to findings below. |
| Clean mixed-era canonical assertion | `test_assert_canonical_accepts_clean_mixed_era_stream` | Covered. |
| Malformed canonical JSON | `test_assert_canonical_rejects_malformed_canonical_json` | Covered. |
| Corrected v2 pairing plus open starts | `test_assert_canonical_enforces_v2_identity_pairing_and_allows_open_starts` | Partly covered; see Finding 1. |
| Missing source/no-write for assert and dry-run reconcile | `test_source_drift_fails_assert_and_reconcile_dry_run_without_writing` | Covered. |
| Apply once and second apply idempotency | `test_reconcile_apply_appends_missing_once_and_rerun_is_byte_identical` | Covered. |
| Whole-batch conflict blocks write | `test_identity_conflict_blocks_full_batch_without_writing` | Covered. |
| Timezone identity without payload rewrite | `test_equivalent_iso_offsets_deduplicate_legacy_identity` | Covered for legacy identity. |
| Explicit file/directory classification | classifier and directory tests | Partly covered; see Findings 2 and 3. |
| Canonical, `.git`, and symlink exclusion | `test_directory_sources_exclude_canonical_git_and_symlinks` | Partly covered; see Finding 2. |
| Malformed declared telemetry | explicit malformed source file in classifier test | Covered for explicit file. |
| Payload redaction and bounded report | `test_json_report_is_bounded_and_never_echoes_payloads` plus `REPORT_KEYS` | Partly covered; see Finding 4. |
| Approved CLI exit semantics | CLI test plus focused shell proof | Partly covered; see Finding 5. |

## RED Reason Assessment

The tests invoke the real CLI through `Open3.capture3`, `RbConfig.ruby`, and
`bin/harnex telemetry`; there is no local fake production implementation. The
reviewed test file does not use source grep or sleeps. The skeleton in
`lib/harnex/commands/telemetry.rb` returns one generic `not_implemented` report
after parsing, and the supervisor proof shows the suite no longer fails on a
missing top-level route.

That is enough to accept GREEN-0 as a deliberately thin seam, but not enough to
accept RED-1. Several tests can still fail only because the skeleton never reads
files before the behavior under test is reached, while their fixtures do not
distinguish the exact regressions Plan 34 elevated after the prior review.

## Findings

1. P1: Corrected v2 identity is still not executable.

Plan 34 requires v2 rows to pair by `(session_id, id, normalized started_at UTC
instant)`, with `session_id` as an additional discriminator rather than a
replacement for `id` and `started_at`. The current v2 test checks an open start,
exact duplicate rows, and a mismatched end with a different `session_id`. It
still does not create two complete valid start/end pairs sharing the same
`session_id` while differing by `id` and/or normalized `started_at`.

A bad implementation that keys v2 canonical state by `session_id` alone can pass
the present v2 fixtures once real scanning exists. RED-1 must add an assertion
that such same-session distinct dispatches are clean and counted as two starts
and two ends, or otherwise proves both identities survive independently.

2. P1: Canonical and symlink directory pruning are not observably pinned.

The directory test proves `.git` pruning because `cx-git-ignored` would alter
the missing count. It does not prove canonical exclusion: scanning the canonical
path as a source only sees an already-present row, so `missing: 1` still passes.
It also does not prove symlink pruning: the symlink points at the same missing
file, so a scanner that follows it can still report one missing identity after
candidate dedupe.

RED-1 must make both failures visible. For example, place a distinct source-only
candidate behind the symlink, and arrange the canonical file so treating it as a
source would change source counts, diagnostics, or status in an asserted way.

3. P2: Explicit file versus directory malformed classification is incomplete.

Plan 34 distinguishes explicit files, which are fatal when malformed, from
directory discovery, which ignores unrelated files and fails malformed sibling
lines only when a file contains at least one recoverable record. The current
classifier test covers a malformed explicit source and an unrelated valid
directory JSON file, but it does not cover a directory-discovered telemetry file
with one recoverable record plus malformed sibling content.

Without that fixture, an implementation can treat all directory malformed JSON
as ignored or all malformed JSON as fatal and still avoid the precise declared
telemetry distinction.

4. P2: Bounded-report truncation is asserted only as a tautology.

The redaction test verifies the secret marker is absent and that diagnostics
size is `<= 50`, but the fixture creates one missing record. That assertion does
not force truncation or a meaningful `diagnostics_truncated` count. Plan 34 asks
for bounded reports with at most 50 diagnostics and a truncated count, never raw
row values or rich sections.

RED-1 should generate more than 50 reportable diagnostics and assert both the
cap and the nonzero truncated count, while preserving the payload-free check.

5. P3: Unknown telemetry option remains unpinned in the full behavioral file.

The staged plan explicitly calls out unknown option handling in GREEN-0/RED-1.
The CLI test covers help, unknown subcommand, `--canonical`/`--global`
conflict, and missing `reconcile --source`, but does not pass an actually
unknown option such as `--definitely-unknown`.

This is small, but it is part of the approved parser/exit-semantics contract and
should be included before the scanner implementation starts.

## Sign-Off

`RED contract executable`: needs_fixes.

Coverage ownership: tests own the public CLI contract directly through
subprocess calls, but the gaps above leave important Plan 34 obligations
unowned.

Scope fidelity: pass. The skeleton remains constrained to routing, parsing, path
labeling, and a bounded `not_implemented` report. I saw no scanner, classifier,
identity, append, or source-read behavior in the skeleton.

Staged thinness exception: pass for GREEN-0 only. RED-1 itself is not ready for
GREEN-1 because some failures remain masked by the single generic skeleton
report before the required observable behavior is reached.
