---
status: draft
issue: 40
plan: 30
tier: B
created: 2026-05-10
phases: 5
---

# Plan 30 — Deployment-fallback on disconnect-rate threshold (#40)

## Goal

Add opt-in deployment-fallback to the codex `app-server` adapter. When
mid-dispatch disconnect rate crosses a configurable threshold, restart
the codex subprocess against an alternate Azure deployment, resume the
same thread, and record per-arm cost metrics in `dispatch.jsonl` so
production data can answer the cache-locality / threshold-tuning
questions the issue defers.

The "what" is canonical in `koder/issues/40_…`. This plan owns "how,
in what order, with what tests."

## Reference pin

- Codex CLI: floor `0.128.0` (same as plan 28). `thread/resume` schema
  unchanged.
- Schema source of truth: `test/fixtures/codex_appserver/schema/ClientRequest.subset.json`.
  `thread/resume` accepts only `threadId` — no model/deployment param.
- Adapter: `lib/harnex/adapters/codex_appserver.rb` (`resume(thread_id:)`
  at L188, subprocess managed by inner `Client`).

## Locked decisions (informed by Q1 finding)

1. **Cross-deployment resume mechanism: subprocess restart.** The Azure
   deployment is set when the codex subprocess starts (env vars + `-c`
   config), not in the JSON-RPC layer. Switching deployments means
   stopping the subprocess and spawning a new one with new config. The
   `threadId` is carried across because conversation state lives in
   codex's local rollout.
2. **Telemetry shape: single-row + per-arm split.** `agent_session_id`
   (= threadId) stays stable across the switch — one logical dispatch,
   two cost arms. New fields: `pre_fallback_*` / `post_fallback_*`
   splits for `disconnections`, `duration_s`, `cached_tokens`,
   `input_tokens`, `output_tokens`. Aggregate fields (existing
   `disconnections`, `duration_s`, etc.) remain whole-dispatch totals
   so non-fallback rows are unchanged.
3. **Trigger granularity: single-shot for v1.** Decide once on first
   threshold trip, no re-evaluation. Simpler; sliding-window can be
   added once telemetry shows whether mid-dispatch re-falls happen.
4. **Adapter scope: codex_appserver only.** PTY codex, claude, generic
   are out of scope for v1. The detection signal (typed disconnect
   events) is only available cleanly on the JSON-RPC adapter.
5. **No multi-fallback chains.** Single alternate only. After fallback
   fires, further disconnects on the alternate deployment are eaten
   the same way as today (force-resume on the same deployment).
6. **Default off.** Fallback fires only when `--fallback-model` and
   `--fallback-disc-threshold` are both supplied.

## Phase 1 — Empirical Q1 verification

Before locking the subprocess-restart approach in code, confirm a
fresh codex `app-server` subprocess can resume a `threadId` it didn't
create. Schema permits it; codex might enforce client identity locally.

Tasks:

- Spawn codex subprocess A → `thread/start` → capture `threadId` →
  `turn/start` → wait for `turn/completed` → kill subprocess.
- Spawn codex subprocess B (fresh, same config OK for v0 of the test)
  → `thread/resume` with the captured `threadId` → `turn/start` →
  expect `turn/completed`.
- Repeat with subprocess B configured for an alternate deployment if a
  test deployment is available; otherwise document the gap and run the
  cross-deployment leg as a follow-up smoke test before merging.

Output: a new `test/integration/codex_resume_across_subprocess_test.rb`
(skipped by default unless `HARNEX_RUN_CODEX_INTEGRATION=1` and the
codex binary is on PATH) plus a one-paragraph note in this plan
recording the result.

If verification fails: pause Phase 2 and revisit Decision 2
(may need to fall back to the two-row shape).

## Phase 2 — Subprocess restart machinery

Extend the codex_appserver adapter's inner `Client` so it can be
swapped under a stable adapter facade.

Tasks:

- `Client#stop_for_fallback(grace_s:)` — issue `turn/interrupt` for
  any in-flight turn, drain pending RPC, terminate subprocess with
  TERM/KILL grace identical to existing teardown path. Preserve
  `@thread_id` for the new client.
- `Client.spawn_with_fallback(prior_thread_id:, deployment_config:)` —
  builds a new subprocess against the alternate deployment, runs the
  initialize handshake, calls `thread/resume(threadId)`. Returns the
  new client.
- `CodexAppserver#switch_deployment(deployment_config:)` — public
  adapter entry point. Captures `pre_fallback` counter snapshot,
  swaps `@client`, signals `Session` to reset per-turn measurement
  state, emits a `fallback_triggered` event into the events log.

Tests (`test/harnex/adapters/codex_appserver_fallback_test.rb`):

- Stub two RPC endpoints. `switch_deployment` cleanly stops the first,
  spawns the second, resumes the same threadId, sends a turn through
  the second.
- Subprocess teardown bounded — no orphan PIDs after a forced stop
  during in-flight turn.
- `agent_session_id` in dispatch row equals the original threadId
  after fallback (stability check).

## Phase 3 — Disconnect-rate threshold detection

Detection lives where existing disconnect counting lives:
`runtime/session.rb` (around the `disconnections` counter at L28
referenced by plan 28).

Tasks:

- Extend `EventCounters` with `record_disconnection_at(timestamp_ms)` —
  appends to a bounded ring (size = max threshold-window seconds × an
  upper bound per-second rate, conservatively 600 entries).
- `EventCounters#disconnect_rate_in_window(window_s)` returns
  `count_in_last(window_s)`.
- New module `Harnex::Runtime::FallbackTrigger` with:
  - `parse(flag_value)` — accepts `"5/60s"` shape, returns
    `{count: 5, window_s: 60}`. Rejects malformed values up front in
    `harnex run` flag parsing.
  - `should_trigger?(counters, threshold:, already_fired:)` — returns
    true on first crossing only (single-shot per Decision 3).

Tests (`test/harnex/runtime/fallback_trigger_test.rb`):

- Window math: 5 disconnects within 60s trips; 5 disconnects spread
  over 120s does not.
- Single-shot: trips once even if rate stays high.
- Flag parser rejects `5/60`, `5/60m`, empty, negative.

## Phase 4 — Per-arm telemetry split

Schema additions (additive, default null/0 when no fallback):

`actual.*`:
- `pre_fallback_disconnections`, `post_fallback_disconnections`
- `pre_fallback_duration_s`, `post_fallback_duration_s`
- `pre_fallback_cached_tokens`, `post_fallback_cached_tokens`
- `pre_fallback_input_tokens`, `post_fallback_input_tokens`
- `pre_fallback_output_tokens`, `post_fallback_output_tokens`
- `fallback_triggered` (bool)
- `fallback_to` (string, the alternate model name)
- `fallback_at_disc_count` (int)
- `fallback_at_wallclock_s` (number)

Aggregate counters (`disconnections`, `duration_s`, `cached_tokens`,
`input_tokens`, `output_tokens`) keep their meaning: whole-dispatch
totals = pre + post.

Tasks:

- Snapshot counters at fallback-trigger time. Snapshot stored on
  `Session`; emitted into the `actual` block at row-write time.
- Update `test/dispatch_row_schema_test.rb`:
  - Existing test: extend `ACTUAL_KEYS` with the new fields. Confirm
    no-fallback rows have nil/0 for splits and `fallback_triggered: false`.
  - New test: simulate a fallback path, assert splits sum to aggregate.
- Update `docs/dispatch-telemetry.md` with the new fields and the
  aggregate-vs-split semantics.

## Phase 5 — CLI flags + docs + integration test

Tasks:

- `harnex run` flags:
  - `--fallback-model <name>` — required for fallback to be active.
  - `--fallback-disc-threshold <N>/<window>s` — required.
  - `--fallback-deployment-env <K=V,K=V>` — optional override of env
    vars for the fallback subprocess (e.g. `OPENAI_BASE_URL=…`). If
    omitted, inherits parent process env. Plan-write *intentionally
    leaves room here* — exact shape may shift in Phase 5 if a JSON
    blob via `--meta` proves cleaner.
- Reject combinations: any one of the three above without
  `codex_appserver` adapter → fail at flag-parse with a clear message.
- Docs:
  - `docs/codex-appserver.md` — section on fallback, when to use,
    what trips it.
  - `docs/dispatch-telemetry.md` — per-arm splits + trigger fields.
  - `koder/issues/40_…` — flip status to `closed` on merge with a
    pointer to the release.
- Integration test (`test/harnex/commands/run_fallback_test.rb`,
  HARNEX_RUN_CODEX_INTEGRATION-gated):
  - Stub deployment A that disconnects on a regular cadence;
    deployment B that completes normally.
  - Real `harnex run` subprocess; assert dispatch row shows
    `fallback_triggered: true`, splits populated, post-fallback
    completes successfully.
  - Negative: same setup minus flags → no fallback fires, row
    unchanged.

## Out of scope (carried from issue)

- Auto-detection / auto-tuning of fallback target.
- Multi-fallback chains.
- Cross-adapter fallback.
- Sliding-window trigger (deferred until v1 telemetry shows demand).

## Risk register

- **Q1 verification fails empirically.** Mitigation: Phase 1 first;
  if it fails, plan revisits Decision 2 before Phase 2 starts.
- **Subprocess teardown race during in-flight turn.** Mitigation:
  reuse the bounded TERM/KILL teardown machinery already shipped for
  `--auto-stop` (issue #37), test under load.
- **Counter snapshot drift.** Aggregates and splits must always
  reconcile (`pre + post == aggregate`). Schema test enforces this.
- **Cache-cold cost on fallback worse than reconnect cost.** This is
  exactly what the telemetry is designed to measure; not a
  correctness risk, a tuning question. Default-off keeps the blast
  radius zero until an opt-in user has data.
