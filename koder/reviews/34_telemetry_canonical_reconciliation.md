# Plan 34 Review — Canonical telemetry reconciliation

Verdict: changes_requested

Scope reviewed:

1. `koder/issues/67_telemetry_canonical_reconciliation.md`
2. `koder/plans/34_telemetry_canonical_reconciliation.md`
3. `lib/harnex/dispatch_history.rb`
4. `lib/harnex/commands/history.rb`
5. `lib/harnex/cli.rb`
6. `test/harnex/dispatch_history_test.rb`

I did not run tests. This is a plan review only.

## Findings

### P1-1. v2 candidate identity is not collision-safe for reused session IDs

Plan evidence: Plan 34 requires v2 rows to carry nonempty `id`, `session_id`,
and parseable `started_at`, but then identifies recoverable v2 rich ends by
"nonempty `session_id` when present" and only falls back to `(id, normalized
started_at UTC instant)` otherwise (`koder/plans/34_telemetry_canonical_reconciliation.md`,
"Record and identity contract", lines 81-110).

Issue evidence: Issue 67 says recovery identified dispatches by `(id,
started_at instant)` because IDs are reused and timestamps can use different
offsets (`koder/issues/67_telemetry_canonical_reconciliation.md`, lines 20-27).
The review brief also requires identity to be safe for reused IDs, session IDs,
and timezone offsets.

Why this is unsafe: two distinct dispatches with a reused session ID collapse to
one v2 identity. The reconciler could then mark a missing row as present, report
a false conflict, or suppress a legitimate append. Current builders persist all
three fields on v2 starts and ends (`lib/harnex/dispatch_history.rb`, lines
145-188), so the safer identity is available.

Required replacement language:

```text
Identity:

- v2 rich end rows require nonempty `session_id`, nonempty `id`, and parseable
  `started_at`. Their identity is `(session_id, id, normalized started_at UTC
  instant)`. `session_id` is an additional discriminator, not a substitute for
  dispatch ID and start instant.
- envelope-less legacy rich rows have no trusted session ID. Their identity is
  `(id, normalized started_at UTC instant)` where both fields come from `meta`.
- Canonical duplicate/conflict checks compare identities inside the same family.
  A v2 row and a legacy rich row may be considered the same recovered dispatch
  only when `id` and normalized `started_at` match and their recoverable payload
  is semantically equal; otherwise report a conflict with both path:line
  locations.
- Comparison uses parsed JSON object equality for payloads, not byte order.
  Equivalent timezone offsets normalize for identity only; payload text is not
  rewritten.
```

Also replace the modern-v2 uniqueness bullets with:

```text
- one start row and one end row per `(session_id, id, normalized started_at UTC
  instant)`;
- a v2 end must have exactly one start with matching `session_id`, `id`, and
  normalized `started_at` instant;
- a second v2 row with the same identity and record type is a duplicate if its
  parsed payload is equal, otherwise an identity conflict;
- an unpaired start is allowed and counted as `open_starts`.
```

### P2-1. Directory-source legacy-rich detection is too broad

Plan evidence: Plan 34 treats envelope-less legacy rich candidates as rows with
nonempty `meta.id`, parseable `meta.started_at`, and an `actual` hash (lines
92-99). The same plan requires directory discovery to ignore unrelated JSON and
files with no recoverable rich records (lines 112-123), and Phase 1 asks the
reviewer to check that queue/session summaries cannot be mistaken for rich
dispatches (lines 173-184).

Current source context: existing tests document an envelope-less object with
`meta`, `predicted`, and `actual` that history skips because it is not a current
reader end row (`test/harnex/dispatch_history_test.rb`, lines 303-320). Current
rich rows also have a known harnex summary section set from
`build_summary_record`: `actual`, `agent`, `attempt`, `attribution`, `context`,
`meta`, `outcome`, `predicted`, `reliability`, and `usage` (lines 31-55).

Why this needs tightening: `meta.id` + `meta.started_at` + `actual` is a
plausible shape for non-dispatch summaries. In directory scans that can turn
unrelated `.json` or `.jsonl` files into recovery candidates and then into
missing/conflict decisions, contradicting Issue 67's directory-scan safety
contract (`koder/issues/67_telemetry_canonical_reconciliation.md`, lines 77-80).

Required replacement language:

```text
Only rich dispatch end records are recoverable:

- v2 `schema_version == 2` and `record_type == "dispatch_end"`, with nonempty
  `session_id`, nonempty `id`, parseable `started_at`, and an `actual` hash; or
- envelope-less legacy rich dispatch summaries with `meta` hash, nonempty
  `meta.id`, parseable `meta.started_at`, an `actual` hash, and at least two
  additional known harnex rich-summary section keys from this set:
  `predicted`, `agent`, `usage`, `context`, `attribution`, `outcome`,
  `attempt`, `reliability`.

Thin v1 rows, start rows, generic JSON, queue summaries, receipts, and claims
are ignored as recovery candidates. A directory-discovered file whose only
would-be candidates fail the rich-dispatch shape is ignored, not treated as
malformed telemetry.
```

Add this RED test requirement after Phase 2 item 9:

```text
10. a directory source containing a generic JSON summary with `meta.id`,
    `meta.started_at`, and `actual`, but without the required harnex rich-summary
    section evidence, is ignored and does not produce drift or conflicts;
```

Renumber the following test bullets.

### P3-1. The plan overstates reader compatibility for envelope-less rich rows

Plan 34 first says `harnex history` accepts v1 thin and v2 rows while skipping
older envelope-less rich rows (lines 28-33), but later calls envelope-less rich
rows "legacy end rows already accepted by harnex readers" (lines 73-79).

Current source agrees with the first statement, not the second:
`DispatchHistory.end_record?` accepts v2 `dispatch_end` and v1 rows with
`schema_version == 1`, `status`, and no `record_type`
(`lib/harnex/dispatch_history.rb`, lines 75-80); `History#derived_records` only
emits `start_record?` and `end_record?` rows
(`lib/harnex/commands/history.rb`, lines 85-109); and the tests verify
envelope-less pre-0.7.3 telemetry is skipped by history
(`test/harnex/dispatch_history_test.rb`, lines 303-320).

This does not block execution if P2-1 tightens the recovery classifier, but the
wording should say legacy rich recovery is new reconciler behavior, not current
history-reader behavior.

## Pass Checks

- The CLI surface is appropriately small: one `telemetry` namespace with two
  subcommands, no aliases, no config/env knobs, and existing parse-error
  semantics (`koder/plans/34_telemetry_canonical_reconciliation.md`, lines
  39-64; `lib/harnex/cli.rb`, lines 7-55).
- The plan preserves mixed historical streams and avoids schema migration,
  deletion, rewriting, sorting, and source cleanup (Issue 67 lines 53-66; Plan
  34 lines 129-145).
- Modern unpaired starts are allowed and counted rather than rejected, matching
  current history behavior for running/interrupted starts
  (`lib/harnex/commands/history.rb`, lines 85-127; test lines 261-300).
- The mutation sequence is directionally safe: validate canonical, collect all
  sources, fail before writes on fatal/conflict, acquire one exclusive lock,
  re-read under lock, append only still-missing rows, flush, then post-check
  (`koder/plans/34_telemetry_canonical_reconciliation.md`, lines 129-145).

## Required Before RED Tests

1. Apply the P1 identity replacement so v2 reconciliation cannot key solely on
   `session_id`.
2. Apply the P2 source-candidate replacement and add the generic-summary RED
   test requirement.
3. Optionally fix the P3 wording to avoid conflating current `history` readers
   with the new recovery classifier.
