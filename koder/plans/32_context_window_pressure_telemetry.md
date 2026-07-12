---
status: implemented
issue: 54
plan: 32
tier: B
layer: context-pressure-telemetry
created: 2026-07-12
phases: 3
---

# Plan 32 — Active context-window pressure telemetry (#54)

## Capability

Every completed dispatch records bounded, provenance-aware terminal and peak
active-context pressure without conflating it with cumulative token usage.

## Locked decisions

1. **The block is additive and always present.** Dispatch rows gain a stable
   top-level `context` block; existing `usage` and legacy `actual` fields remain
   unchanged.
2. **The stable keys are:** `status`, `source`, `terminal_tokens`,
   `window_tokens`, `terminal_percent`, `peak_tokens`, `peak_percent`,
   `samples`, `missing_samples`, and `latest_sample_status`.
3. **Terminal means final valid occupancy sample.** A later unavailable sample
   increments `samples` and `missing_samples`, sets `latest_sample_status` to
   `missing`, and does not erase terminal or peak values. Thus post-compaction
   null is visible without becoming zero.
4. **Pi is observed; Codex is estimated.** Pi's dedicated
   `get_session_stats.contextUsage` signal uses `status=observed` and
   `source=pi_get_session_stats`. Codex uses `status=estimated` and
   `source=codex_thread_token_usage_last`: upstream defines
   `last.totalTokens` as the latest active context size, but locally appended
   items after the latest model response are not represented, and Harnex
   derives percentage from `modelContextWindow`.
5. **Percent is full-window pressure.** Pi's reported percentage is retained.
   Codex is `last.totalTokens / modelContextWindow * 100`, rounded to two
   decimals; it is not Codex TUI's baseline-adjusted “context left” display.
6. **Sampling stays bounded.** Pi samples on existing completion/final stats
   refreshes and after compaction; Codex samples only token-usage
   notifications. Harnex stores an in-memory aggregate, not every payload.
7. **No content enters telemetry.** Prompt text, transcripts, messages, tool
   payloads, and compaction summaries remain excluded.

## Source verification

- Pi `0.80.6` RPC documentation defines `contextUsage` as the current context
  estimate used for compaction/footer display and explicitly makes
  `tokens`/`percent` null immediately after compaction.
- Codex `rust-v0.144.1` protocol maps `ThreadTokenUsage.last` from core
  `last_token_usage`; the same release documents that its `total_tokens` is the
  latest active context size and that local items after the latest model output
  are not reflected. This is why the wire value is useful but conservatively
  classified as estimated by Harnex.

## Result — 2026-07-12

Implemented all three phases. The full suite passes with 524 runs, 2012
assertions, 0 failures, 0 errors, and 2 skips. #54 is implemented/unreleased.

## Phase 1 — Shared accumulator and summary schema

- Add a small context accumulator that validates numeric samples, retains the
  final valid sample, and updates independent token/percentage high-water marks.
- Add adapter capability/source hooks with unsupported defaults.
- Normalize the aggregate at session finalization and append the stable
  top-level block for observed, estimated, missing, and unsupported adapters.
- Extend the dispatch-row schema regression test.

## Phase 2 — Structured adapter producers

- Map Pi `contextUsage.{tokens,contextWindow,percent}` into the accumulator.
- Permit repeated bounded Pi stats requests and sample after `compaction_end`;
  avoid double-counting the synchronous final refresh.
- Map Codex `tokenUsage.last.totalTokens` plus `modelContextWindow` on each
  `thread/tokenUsage/updated` notification while preserving cumulative
  `tokenUsage.total` for `usage`.

## Phase 3 — Proof and documentation

- Cover Pi observed/multi-sample/null-after-compaction behavior.
- Cover Codex estimated occupancy and cumulative-usage separation.
- Cover supported-but-missing and unsupported stable blocks.
- Document field semantics, provenance, null handling, and the distinction from
  cumulative usage in `docs/dispatch-telemetry.md` and `CHANGELOG.md`.
- Run focused tests, then the full suite.

## Acceptance criteria

- [x] Pi terminal and peak pressure survive multiple stats samples.
- [x] A final null Pi sample is counted and marked missing without erasing the
      final valid or peak sample.
- [x] Codex captures `last.totalTokens` and `modelContextWindow` conservatively
      as an estimate while cumulative `total` remains in `usage`.
- [x] Supported adapters with no valid sample report `missing`; other adapters
      report `unsupported`.
- [x] The context block has the same keys on every dispatch row.
- [x] Existing summary fields and consumers remain compatible.
- [x] Focused and full test suites pass.

## Deferred / non-goals

- Primary-orchestrator telemetry (#55).
- Automatic compaction, warnings, thresholds, or session rotation.
- Per-sample event streams or historical-row migration.
- Queue-level context rollups.

## Stop rules

- Stop if a source cannot distinguish active occupancy from cumulative usage.
- Stop rather than infer occupancy from PTY text or cumulative token totals.
- Split follow-up work if runtime policy or primary-orchestrator capture becomes
  necessary to complete this telemetry-only slice.

## Verification

```bash
ruby -Ilib -Itest test/harnex/adapters/pi_test.rb
ruby -Ilib -Itest test/harnex/runtime/session_pi_rpc_test.rb
ruby -Ilib -Itest test/harnex/runtime/session_jsonrpc_test.rb
ruby -Ilib -Itest test/harnex/runtime/session_test.rb
ruby -Ilib -Itest test/dispatch_row_schema_test.rb
ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'
```
