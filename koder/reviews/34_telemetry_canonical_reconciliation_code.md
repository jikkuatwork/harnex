# Plan 34 Canonical Telemetry Implementation Review

Verdict: changes_requested

Review target: current `main` at `27ce3cb`, covering GREEN-0 `067330b`,
GREEN-1 `e450f4b`, and approved tests `526390c`.

Scope read: Issue 67; Plan 34; final RED-1 rereview; telemetry test file;
telemetry reconciler; telemetry command; dispatch history; CLI; loader; dispatch
guide historical telemetry notes.

I did not edit source/tests/plan/issue/docs, and I did not run product tests,
per review brief.

## Findings

### P1 — Legacy rich recognition skips the real pre-v2 mirror family

The reconciler still requires at least two top-level rich section keys before a
legacy envelope-less row is recoverable. `legacy_rich?` accepts only rows with
`meta.id`, parseable `meta.started_at`, `actual` hash, and at least two keys from
`predicted`, `agent`, `usage`, `context`, `attribution`, `outcome`, `attempt`,
`reliability` (`lib/harnex/telemetry_reconciler.rb:330` through
`lib/harnex/telemetry_reconciler.rb:338`). The real runtime miss provided to this
review has only top-level `actual`, `meta`, and `predicted`, with
`meta.harness == "harnex"`. That gives one rich-section key, so the row is
silently ignored: `source_candidate` only returns a candidate for `v2_rich_end?`
or `legacy_rich?` (`lib/harnex/telemetry_reconciler.rb:312` through
`lib/harnex/telemetry_reconciler.rb:317`), and source summaries count only
accepted rows as candidates (`lib/harnex/telemetry_reconciler.rb:219` through
`lib/harnex/telemetry_reconciler.rb:223`).

This violates Issue 67's recovery target for old scratch-file rich rows:
discover rich rows, identify them by `(id, started_at instant)`, distinguish
duplicates from conflicts, and append genuinely missing rows
(`koder/issues/67_telemetry_canonical_reconciliation.md:20` through
`koder/issues/67_telemetry_canonical_reconciliation.md:31`). It also violates
the goal that mixed historical streams include envelope-less rich rows tolerated
and recovered rather than migrated (`koder/issues/67_telemetry_canonical_reconciliation.md:53`
through `koder/issues/67_telemetry_canonical_reconciliation.md:54`).

The approved tests do not guard this historical shape. The `legacy_rich` fixture
always includes all rich section keys, including `agent`, `usage`, `context`,
`attribution`, `outcome`, `attempt`, and `reliability`
(`test/harnex/telemetry_reconciler_test.rb:410` through
`test/harnex/telemetry_reconciler_test.rb:424`). The generic-summary negative
fixture has `meta` and `actual` but no rich harnex evidence
(`test/harnex/telemetry_reconciler_test.rb:234` through
`test/harnex/telemetry_reconciler_test.rb:237`). There is no test for the real
`meta`/`predicted`/`actual` family with `meta.harness: harnex`, so the exact
runtime miss can report `candidates=0`, `missing=0`, `status=clean`, and exit
`0`.

Fix requirement: classify the real historical family as a recoverable legacy
rich dispatch row without broadening into generic summaries. A bounded rule such
as `meta.harness == "harnex"` plus nonempty `meta.id`, parseable
`meta.started_at`, `actual` hash, and at least one known rich section would
cover the observed family while keeping generic summaries ignored.

Test requirement: add a fixture copied from or structurally identical to the
real Holm row shape: top-level `actual`, `meta`, `predicted`; `meta.id`;
`meta.started_at`; `meta.harness == "harnex"`; no second rich-section key. The
test must fail `assert-canonical --source`/dry-run as drift when absent from
canonical, must apply exactly once, and must become clean on the second apply.

Runtime miss disposition: confirmed. The implementation's current classifier
explains the supervisor-observed `files_scanned=1`, `candidates=0`,
`missing=0`, clean exit for the exact pre-v2 row family. Release and Holm wiring
should stay blocked until this is fixed and tested against that shape.

### P2 — Cross-family source conflicts can be appended together

The source conflict pass groups only by full row identity
(`lib/harnex/telemetry_reconciler.rb:364` through
`lib/harnex/telemetry_reconciler.rb:369`). Full identity includes the family
prefix: v2 rows use `["v2", session_id, id, started_at]`, while legacy rows use
`["legacy", id, started_at]` (`lib/harnex/telemetry_reconciler.rb:341` through
`lib/harnex/telemetry_reconciler.rb:353`). A v2 `dispatch_end` and legacy rich
row for the same dispatch instant but different payloads will therefore not
conflict before mutation.

That is contrary to the Plan 34 identity contract: a v2 row and a legacy rich
row may be considered the same recovered dispatch only when `id` and normalized
`started_at` match and recoverable payload is semantically equal; otherwise the
tool must report a conflict with both locations
(`koder/plans/34_telemetry_canonical_reconciliation.md:119` through
`koder/plans/34_telemetry_canonical_reconciliation.md:123`). The current
cross-family comparison exists only when matching source rows against canonical:
`find_match` falls back to `match_identity`
(`lib/harnex/telemetry_reconciler.rb:357` through
`lib/harnex/telemetry_reconciler.rb:361`), and `rows_payload_equal?` compares
cross-family rich payloads (`lib/harnex/telemetry_reconciler.rb:408` through
`lib/harnex/telemetry_reconciler.rb:419`). It is not applied among source rows
before append.

The mutation path then dedupes missing rows by full family identity only
(`lib/harnex/telemetry_reconciler.rb:373` through
`lib/harnex/telemetry_reconciler.rb:381`). Under lock, it reruns the same
analysis and appends each still-missing row whose full identity appeared in the
pre-lock row list (`lib/harnex/telemetry_reconciler.rb:384` through
`lib/harnex/telemetry_reconciler.rb:400`). With an empty canonical or no matching
canonical row, the conflicting v2 and legacy source records can both remain
missing and both be appended.

Fix requirement: run the same cross-family `match_identity` and semantic-payload
comparison across source candidates before any write. Equal cross-family source
duplicates should dedupe to one append; differing payloads should be a conflict
that blocks the entire batch.

Test requirement: add a source file or repeated sources containing a v2
`dispatch_end` and legacy rich row with the same `id` and equivalent
`started_at` instant, one equal-payload case and one different-payload case. The
different-payload case must leave canonical bytes unchanged under `--apply`.

## Checklist Disposition

Legacy rich candidate recognition: fail, see P1. The exact
`meta`/`predicted`/`actual` runtime family is silently skipped.

Tests for real historical shape: fail, see P1. Current fixtures cover rich rows
with many section keys and generic summaries with none, but not the observed
one-section harnex row.

Corrected v2 identity and pairing: pass for canonical v2 rows. Validation keys
on `(session_id, id, normalized started_at)` (`lib/harnex/telemetry_reconciler.rb:174`
through `lib/harnex/telemetry_reconciler.rb:188`), and tests pin shared-session
non-collision (`test/harnex/telemetry_reconciler_test.rb:86` through
`test/harnex/telemetry_reconciler_test.rb:117`).

Explicit-file versus directory malformed/classifier policy: pass for the tested
scope. Explicit malformed sources fail, directory files with recoverable rows
and malformed sibling lines fail, and unrelated generic JSON is ignored
(`lib/harnex/telemetry_reconciler.rb:251` through
`lib/harnex/telemetry_reconciler.rb:267`).

All conflicts/fatals before write: partial fail, see P2. Canonical and
same-family source conflicts are known, but cross-family source conflicts are
not.

One-lock under-lock reread/recheck: pass for the implemented analysis. Apply
takes one exclusive lock, rereads/reanalyzes, filters still-missing rows, writes
one payload, and post-validates (`lib/harnex/telemetry_reconciler.rb:25` through
`lib/harnex/telemetry_reconciler.rb:35`; `lib/harnex/telemetry_reconciler.rb:384`
through `lib/harnex/telemetry_reconciler.rb:400`).

Dry-run/assert mutation: pass. Only `reconcile --apply` reaches
`append_missing_under_lock` (`lib/harnex/telemetry_reconciler.rb:25` through
`lib/harnex/telemetry_reconciler.rb:30`), and tests pin assert/dry-run byte
stability (`test/harnex/telemetry_reconciler_test.rb:121` through
`test/harnex/telemetry_reconciler_test.rb:136`).

Append-only/idempotency: pass for non-conflicting recognized rows. The code
uses end-of-file write only (`lib/harnex/telemetry_reconciler.rb:397` through
`lib/harnex/telemetry_reconciler.rb:399`), and the second-apply test requires
byte identity (`test/harnex/telemetry_reconciler_test.rb:139` through
`test/harnex/telemetry_reconciler_test.rb:156`).

Reports and diagnostics bounded/no raw payload: pass for reviewed paths.
Diagnostics cap at 50 (`lib/harnex/telemetry_reconciler.rb:459` through
`lib/harnex/telemetry_reconciler.rb:464`), and the secret-marker test exercises
stdout/stderr redaction plus truncation (`test/harnex/telemetry_reconciler_test.rb:254`
through `test/harnex/telemetry_reconciler_test.rb:284`).

CLI exits/help/options: pass. The route is loaded
(`lib/harnex.rb:14`, `lib/harnex.rb:41`), dispatched
(`lib/harnex/cli.rb:44` through `lib/harnex/cli.rb:45`), exposed through help
(`lib/harnex/cli.rb:96` through `lib/harnex/cli.rb:97`), and option conflicts
are explicit (`lib/harnex/commands/telemetry.rb:80` through
`lib/harnex/commands/telemetry.rb:90`).

No hidden second destination/config/migration/cleanup: pass. Dispatch docs still
say every dispatch writes one start and one rich end row to the only canonical
stream (`guides/01_dispatch.md:146` through `guides/01_dispatch.md:149`), and
Plan 34 non-goals remain unimplemented in the reviewed surface.

## Verification

Not run: product tests, by review instruction.
