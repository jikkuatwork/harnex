# Plan 34 Finding-Closure Rereview

Verdict: pass

Scope:

1. Prior review: `koder/reviews/34_telemetry_canonical_reconciliation.md`
2. Corrected plan: `koder/plans/34_telemetry_canonical_reconciliation.md`
3. Corrected issue: `koder/issues/67_telemetry_canonical_reconciliation.md`
4. Correcting commit: `80939a4`
5. Source context: `lib/harnex/dispatch_history.rb`

I did not rerun tests. This rereview only checked whether commit `80939a4`
closes the findings from the prior Plan 34 review without adding a new P1/P2
contradiction.

## Finding Closure

| Finding | Prior requirement | Rereview result |
| --- | --- | --- |
| P1-1 | Do not key v2 candidates by `session_id` alone; require `(session_id, id, normalized started_at UTC instant)` and compare cross-family recovery by `id`, normalized start instant, and semantic payload equality. | Closed. Plan 34 now states that v2 rich end identity is `(session_id, id, normalized started_at UTC instant)`, that `session_id` is an additional discriminator, and that v2/legacy recovery equivalence requires matching `id`, normalized `started_at`, and semantic payload equality. The modern-v2 uniqueness bullets were also replaced with one start and one end per full v2 identity, duplicate-vs-conflict wording, exact start/end matching, and allowed `open_starts`. |
| P2-1 | Tighten directory-source legacy-rich detection so generic summaries with `meta.id`, `meta.started_at`, and `actual` are ignored unless they show rich harnex dispatch evidence. | Closed. Plan 34 now limits recoverable candidates to v2 rich `dispatch_end` rows with `actual`, or envelope-less legacy rich summaries with `meta`, `actual`, and at least two known harnex rich-summary section keys. It explicitly ignores thin v1 rows, start rows, generic JSON, queue summaries, receipts, and claims, and adds the requested RED test for a generic JSON summary that must not produce drift or conflicts. Issue 67 acceptance criteria now also require directory sources to ignore generic summaries unless they match the rich dispatch end shape. |
| P3-1 | Stop describing envelope-less rich rows as already accepted by current `harnex history` readers. | Closed. Plan 34 now says canonical validation accepts thin v1 and envelope-less rich rows, while envelope-less rich recovery is new reconciler behavior and current `harnex history` readers skip those rows. This matches `DispatchHistory.end_record?`, which accepts v2 `dispatch_end` and thin v1 rows but not envelope-less rich summaries. |

## Remaining Findings

None.

## Notes

- `80939a4` changes only `.harnex/dispatch.jsonl`, Issue 67, and Plan 34.
- No new P1/P2 contradiction was found within the bounded rereview scope.
- Source inspection was limited to `lib/harnex/dispatch_history.rb` to verify
  the corrected reader-compatibility statement for envelope-less rich rows.
