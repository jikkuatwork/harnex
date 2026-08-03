# Plan 34 P1/P2 Code Fix Rereview

Verdict: pass

Review target: fix commit `d9d0e77` on `main`, against the P1/P2 findings in
`koder/reviews/34_telemetry_canonical_reconciliation_code.md`.

Scope read:
1. Prior code review: `koder/reviews/34_telemetry_canonical_reconciliation_code.md`
2. Fix diff: `git show d9d0e77`
3. Reconciler: `lib/harnex/telemetry_reconciler.rb`
4. Tests: `test/harnex/telemetry_reconciler_test.rb`
5. Plan contract excerpt: `koder/plans/34_telemetry_canonical_reconciliation.md`

I did not run product tests, per rereview instruction. I did not edit source,
tests, issue, plan, changelog, version, docs, or `koder/STATE.md`.

## P1 Closure - Legacy rich recognition skips real pre-v2 mirror family

The prior failure was that a real envelope-less legacy rich row with top-level
`meta`, `predicted`, and `actual` was skipped because the classifier required at
least two rich section keys. The fixed classifier still requires a JSON object,
`meta` hash, nonempty `meta.id`, parseable `meta.started_at`, and an `actual`
hash. It now also accepts either the old two-rich-key shape or a bounded
`meta.harness == "harnex"` shape with at least one known rich key
(`lib/harnex/telemetry_reconciler.rb:330` through
`lib/harnex/telemetry_reconciler.rb:340`).

That closes the exact runtime family described by the prior review without
making generic summaries recoverable. A generic object with `meta`, `actual`,
and no known rich key remains ignored, and the existing classifier test still
pins that negative case (`test/harnex/telemetry_reconciler_test.rb:296` through
`test/harnex/telemetry_reconciler_test.rb:323`).

The fix also adds the missing incident fixture:
`test_real_pre_v2_harnex_rich_shape_recovers_once_and_becomes_clean`
constructs the real shape with only `meta`, `predicted`, and `actual`, including
`meta.harness == "harnex"` (`test/harnex/telemetry_reconciler_test.rb:141`
through `test/harnex/telemetry_reconciler_test.rb:173`, helper at
`test/harnex/telemetry_reconciler_test.rb:499` through
`test/harnex/telemetry_reconciler_test.rb:518`).

Actual legacy row disposition: closed. The row family that previously produced
`candidates=0`, `missing=0`, clean exit now has a dedicated regression that
requires `sources.candidates == 1`, `missing == 1`, assert/dry-run byte
stability, one append on apply, clean assert after apply, and byte identity on a
second apply.

False-positive disposition: not weakened beyond the requested closure. The new
one-rich-key path is gated by `meta.harness == "harnex"`, valid dispatch
identity fields, and an `actual` hash; unrelated generic summaries are still
excluded.

## P2 Closure - Cross-family source conflicts can be appended together

The prior failure was that source conflict detection grouped only by full row
identity, so a v2 row and legacy rich row for the same dispatch instant could
both be appended if their payloads differed. The fix now performs a second
source conflict pass grouped by cross-family `match_identity`, compares only
v2-vs-legacy pairs, and records a conflict unless `rows_payload_equal?` says the
recoverable payload is semantically equal
(`lib/harnex/telemetry_reconciler.rb:365` through
`lib/harnex/telemetry_reconciler.rb:380`).

The source dedupe path also changed from full-family dedupe to
`dedupe_source_rows`, which selects a single row for equal cross-family
duplicates and keeps conflicting rows visible to the conflict report
(`lib/harnex/telemetry_reconciler.rb:383` through
`lib/harnex/telemetry_reconciler.rb:393`). This preserves append-only behavior:
`reconcile --apply` still writes only at EOF under one lock, after an under-lock
reread and reanalysis (`lib/harnex/telemetry_reconciler.rb:411` through
`lib/harnex/telemetry_reconciler.rb:430`).

The added regression covers both sides of the Plan 34 identity contract:
`test_cross_family_source_rows_dedupe_equal_payloads_and_block_conflicts`
requires equivalent v2/legacy source rows to append once, and a same
`id`/normalized `started_at` pair with different payload to report conflict and
leave canonical bytes unchanged (`test/harnex/telemetry_reconciler_test.rb:215`
through `test/harnex/telemetry_reconciler_test.rb:249`).

Locking and append-only disposition: preserved. The conflict is detected before
write eligibility, and the under-lock reanalysis still blocks mutation if any
fatal or conflict appears.

Redaction and bounded diagnostics disposition: unchanged. The new diagnostics
reuse the existing `identity_label` path:line form and do not include raw row
payloads; the report cap remains `MAX_DIAGNOSTICS = 50`.

## Checklist

- Legacy real Harnex `meta`/`predicted`/`actual` row: pass.
- Generic-summary false-positive guard: pass.
- Cross-family equal source duplicate appends exactly once: pass.
- Cross-family same-identity changed payload conflicts with zero write: pass.
- Dry-run/assert byte stability: pass by targeted regression and unchanged write path.
- Under-lock reread/recheck: pass.
- Append-only/idempotency: pass.
- Raw-payload redaction and bounded report shape: pass.

## Verification

Not run: product tests, by review instruction.

Supervisor proof considered: telemetry tests 13 runs / 72 assertions / 0
failures/errors; full suite 671 runs / 2908 assertions / 0 failures/errors / 2
skips; exact real Holm legacy-rich row reports candidate and missing, dry-run
preserves SHA, apply appends once, assert passes, second apply preserves SHA,
and same-identity changed payload conflicts with zero write.

Bounded claims verdict: pass. Open P counts: P1=0, P2=0, P3=0.
