# Harnex State

Updated: 2026-05-24 | 11:08 PM | IST

This is a thin handoff document. Keep it limited to past / present /
future context for the next session. Durable change history belongs in
`CHANGELOG.md`; release verification belongs in `koder/releases/`;
implementation detail belongs in `koder/issues/` or `koder/plans/`.

## Past

- 2026-05-24 | 11:08 PM | IST: #47 queue-aware dispatch telemetry
  contract was filed and a review turn was added in
  `koder/issues/47_queue_aware_dispatch_telemetry.md`; no code changes.
- 2026-05-23 | 07:02 PM | IST: Pi-first docs refresh landed on
  branch `pi-harness` so `harnex` guidance now defaults to `harnex run pi`
  across dispatch/chain/buddy/monitoring/naming + CLI help examples
  (README, `guides/01..05`, `lib/harnex/commands/run.rb`, `lib/harnex/cli.rb`).
  Live smoke validation run: three `harnex run pi --context ... --auto-stop`
  dispatches plus detached `run`+`send` flow succeeded and emitted Pi
  structured telemetry (`adapter_transport=stdio_jsonl_rpc`, cost populated).
- 2026-05-23 | 06:42 PM | IST: #44 + #46 landed together.
  Added first-class `pi --mode rpc` adapter (`Harnex::Adapters::Pi`)
  with structured completion/stop handling, extension-UI dialog
  auto-cancel, synthesized output/tool events, and Pi
  `get_session_stats` telemetry ingestion. Restored DISPATCH
  `actual.cost_usd` (Pi-populated; nullable elsewhere). Added adapter/
  session coverage (`test/harnex/adapters/pi_test.rb`,
  `test/harnex/runtime/session_pi_rpc_test.rb`) and updated docs
  (README, `docs/dispatch-telemetry.md`, `guides/01_dispatch.md`,
  CHANGELOG). Full suite green: 469 runs, 1521 assertions, 0 failures,
  2 skips.
- 2026-05-23 | 04:07 PM | IST: Pi support research captured as
  #44 (first-class `pi --mode rpc` adapter), #45 (deferred Pi PTY
  adapter with extension markers), and #46 (restore `actual.cost_usd`
  by default, starting with Pi structured stats). No code changes yet.
- 2026-05-19 | 09:02 AM | IST: #43 filed to track throughput-first
  telemetry v2 (attempt-level lifecycle, retry/fallback economics,
  attribution enforcement, and throughput KPIs in dispatch rows).
  No code changes yet.
- 2026-05-15 | 10:16 AM | IST: README refreshed for current 0.7.x
  surfaces (OpenCode, Codex app-server default / PTY fallback,
  `--watch` vs `--watch-file`, history, and telemetry fields).
  `docs/dispatch-telemetry.md` and `CHANGELOG.md` were updated with
  the same docs-only correction. No code changes.
- 2026-05-13 | 11:37 PM | IST: #42 filed to track durable
  app-server orchestrator recovery. Decision: skip PTY regex sentry
  for now and make a harnex-managed Codex app-server orchestrator
  recover stream errors through structured error classification,
  subprocess restart, `thread/resume`, bounded recovery prompting, and
  telemetry. No code changes yet.
- 2026-05-13 | 01:47 PM | IST: `harnex 0.7.3` shipped and was
  installed locally. Release commit/tag: `9c8e094` / `v0.7.3`.
  Headline changes: Codex app-server default `service_tier="flex"`
  with `harnex run codex --fast` for `service_tier="fast"`,
  first-class OpenCode adapter, #37/#38/#39 run-command fixes, and
  Codex schema fixtures refreshed against `codex-cli 0.130.0`.
  Verification record: `koder/releases/0.7.3.md`. Full suite green:
  458 runs, 1479 assertions, 0 failures, 2 skips.
- 2026-05-11 | 11:39 PM | IST: OpenCode landed as a first-class PTY
  adapter (`Harnex::Adapters::Opencode`). `harnex run opencode` now
  resolves to a dedicated adapter (not generic), with OpenCode-specific
  `infer_repo_path` handling (`--dir`/`--dir=...` + positional project
  path), double-`Ctrl+C` stop injection, and transcript-tail session id
  extraction from `Continue opencode -s ...`. Added tests in
  `test/harnex/adapters/opencode_test.rb`, updated generic-adapter tests
  to keep unknown-CLI coverage on `aider`, and wired adapter registry in
  `lib/harnex/adapters.rb`. Docs/changelog updated (README/TECHNICAL/
  CHANGELOG). Validation: full suite green under
  `HARNEX_SKIP_SCHEMA_DRIFT=1` (449 runs, 1463 assertions, 0 failures,
  3 skips).
- 2026-05-11 | 03:42 PM | IST: #41 Slice B landed.
  Subprocess-restart machinery for deployment fallback (plan 30
  Phase 2) added inside the new `Harnex::Codex::AppServer` module.
  New on `Client`: class methods `spawn(deployment_config:)` and
  `spawn_with_fallback(prior_thread_id:, deployment_config:,
  handshake_params:, …handlers)`; instance method
  `stop_for_fallback(in_flight_turn:, …grace seconds)` that issues
  a bounded `turn/interrupt`, drains pending RPC, and reuses
  `terminate_process` for TERM/KILL escalation. Adapter gains a
  thin `CodexAppServer#switch_deployment(deployment_config:)` and
  extracts `handshake_initialize_params` so the initial and
  post-fallback handshakes share the same payload. Tests under
  `test/harnex/codex/app_server/` (10 new runs; client_test +
  switch_deployment_test) cover pending-RPC drain, turn/interrupt
  wire-up, real-subprocess TERM/KILL teardown, idempotency,
  threadId stability across the switch, no-orphan PIDs, and
  failure-mode guards (no client / no thread). Suite green: 432
  runs, 1430 assertions, 0 failures, 3 skips under
  `HARNEX_SKIP_SCHEMA_DRIFT=1`. Out of scope for Slice B (deferred
  to plan 30 Phases 3–5): trigger detection, Session-level counter
  snapshots / per-arm telemetry split, `fallback_triggered`
  events-log emission, CLI flags. Issue #41 — Slice C
  (public-API surface doc) remains.
- 2026-05-11 | 01:48 PM | IST: #41 Slice A landed.
  `JsonRpcClient` extracted from
  `lib/harnex/adapters/codex_appserver.rb` to a new file
  `lib/harnex/codex/app_server/client.rb` as
  `Harnex::Codex::AppServer::Client`. Pure refactor, zero behavior
  change; suite green (422 runs, 0 failures) under
  `HARNEX_SKIP_SCHEMA_DRIFT=1`. Sets up the namespace home for
  plan 30 Phase 2 and future codex-specific resilience without
  bloating the adapter. Done via harnex peer dispatch (`cx-i-41`).
  Commits: `a8a71f9` (issue #41), `3a9f0bf` (refactor),
  `989a08c` (dispatch telemetry). Issue #41 frames the broader
  extraction; remaining slices are Slice B (plan 30 Phase 2 in the
  new module) and Slice C (public API surface doc).
- 2026-05-10 | 10:14 PM | IST: plan 30 Phase 1 verified.
  Empirical Q1 confirmed against codex-cli 0.130.0 — fresh subprocess
  can `thread/resume` a `threadId` produced by a torn-down subprocess
  and complete a follow-up turn. New integration test
  `test/integration/codex_resume_across_subprocess_test.rb`
  (skipped unless `HARNEX_RUN_CODEX_INTEGRATION=1` + codex on PATH);
  ~11s wallclock. Same-config / same-deployment only — cross-deployment
  smoke deferred to a Phase 5 pre-merge check. Decision 2 (single-row
  + per-arm split) stands; Phase 2 unblocked. Result paragraph added
  to `koder/plans/30_deployment_fallback.md`.
- 2026-05-10 | 09:26 PM | IST: #40 filed and plan 30 drafted.
  External project filed the issue under a colliding number (31) — renamed
  to #40, fixed heading, committed (`b52b731`). Telemetry section
  expanded with per-arm split shape and ship-to-measure framing
  (`79c630d`). Plan 30 (`e4c133c`, 221 lines, 5 phases) locks
  cross-deployment-resume mechanism (subprocess restart, threadId
  carries via codex local rollout) from the JSON-RPC schema; Q1
  empirical verification gated as Phase 1 before code lands.
- 2026-05-09 | 09:25 PM | IST: #39 landed.
  `Harnex.default_summary_out_path` now defaults every non-empty repo
  root to `<repo>/.harnex/dispatch.jsonl`, independent of legacy
  `koder/` presence. Regression tests cover no-`koder`, legacy
  `koder`, nil/empty roots, and `harnex run` resolution; smoke
  verified no `koder/DISPATCH.jsonl` is created.
- 2026-05-08 | 07:12 PM | IST: F24 / #38 landed. `harnex run`
  now rejects unknown long flags before spawning an agent, points the
  operator at `harnex run --help`, and still forwards everything past
  the explicit `--` separator untouched. Regression tests cover
  `--until`, arbitrary unknown flags, known `--auto-stop`, and agent
  argv passthrough.
- 2026-05-08 | 05:55 PM | IST: F23 / #37 landed. `harnex run
  --auto-stop` now bounds JSON-RPC teardown after `task_complete`
  (default 5s, `HARNEX_AUTOSTOP_TEARDOWN_GRACE_SECONDS` override),
  starts TERM/KILL even when `turn/interrupt` never replies, fails
  pending RPC requests on disconnect, and exits cleanly with no
  registry/orphan tmux residue. Regression test covers a real
  `bin/harnex run codex --auto-stop` subprocess with a stub app-server.
- 2026-05-08 | 12:48 PM | IST: F21 landed. `harnex run` now writes a
  repo-local `.harnex/dispatch.jsonl` terminal record, `harnex history`
  reads it, and docs/tests cover path resolution, status classification,
  commit detection, JSONL output, and a real `harnex run` integration.
- 2026-05-07 | 07:28 PM | IST: #35 Tier 3 landed. DISPATCH dropped
  four always-null fields (`actual.cost_usd`,
  `actual.tests_run|passed|failed`, `meta.agent_deployment`) and
  populated two: `meta.agent_provider` (per-adapter constant —
  claude→anthropic, codex→openai) and `meta.agent_version` (lazy
  `<cli> --version` probe with 2s `Timeout.timeout`, memoized,
  nil on failure). `approvals_handled` left out of schema (deferred
  until policy moves beyond auto-approve-everything); `predicted: {}`
  kept as deliberate JSON Lines stable shape. Schema test updated;
  two new probe tests cover real-binary success and missing-binary
  fallback. Suite green: 402 runs, 1295 assertions.
- 2026-05-07 | 07:30 PM | IST: #35 Tier 2 landed. DISPATCH `actual`
  now carries `turn_count`, `tool_calls`, `commands_executed`,
  `rate_limits`, `output_log_path`, `events_log_path`; `meta`
  auto-derives `parent_dispatch_id` from `$HARNEX_ID` when not in
  passthrough. New `EventCounters#record_item` tallies tool/command
  items from `item/completed`. Schema test extended; suite green
  (400 runs, 1300 assertions). `auto_disconnects` deferred — see the
  issue file for rationale.
- 2026-05-07 | 05:59 PM | IST: #36 Tier 2 landed.
  `Waiter#wait_until_exit` (`lib/harnex/commands/wait.rb`) now polls
  `exit_status_path` for up to 5s after `alive_pid?` flips false,
  before reading exit status. Bounds the DISPATCH-row race that
  affected `harnex wait` callers. Grace is overridable via
  `HARNEX_EXIT_STATUS_GRACE_SECONDS`. Regression test in
  `test/harnex/commands/wait_test.rb` spawns a real subprocess and
  asserts the DISPATCH row is on disk by the time `wait` returns.
  Suite green: 399 runs, 1292 assertions.
- 2026-05-07: #35 Tier 1 (DISPATCH telemetry hygiene) landed.
  Schema regression test in place.
- `harnex 0.6.5` shipped and verified — see `CHANGELOG.md` and
  `koder/releases/0.6.5.md`.

## Present

- #47 is newly filed and reviewed; next step is for the filing agent to
  respond/settle schema decisions before planning implementation.
- #44 and #46 are complete at HEAD; Pi RPC is first-class and validated
  with both tests and live dispatch smokes.
- Pi-first docs/default guidance work is on branch `pi-harness` and ready
  for review/merge.
- #45 is the next Pi track: visible Pi PTY/TUI support only via stable
  extension markers (no brittle screen regex parsing).
- #42 (Codex orchestrator recovery) and #43 (throughput-first telemetry
  v2) remain open.
- Local `harnex --version` reports `harnex 0.7.3 (2026-05-13)`.
- Test command:
  `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`

## Future

1. #47 — have the filing agent respond to the review turn, then draft the
   implementation plan for the queue-aware telemetry contract.
2. Merge/review branch `pi-harness` (Pi RPC + Pi-first docs defaults).
3. #45 — implement Pi PTY/TUI support gated on extension-provided stable
   prompt/readiness markers.
4. #42 — resume Codex app-server orchestrator auto-recovery work.
5. Plan 30 Phases 3–5 — disconnect-rate fallback trigger, per-arm
   telemetry split, and fallback CLI flags.
6. #41 Slice C — public API surface doc at `docs/public_api.md`.
7. #43 — throughput-first telemetry v2 (attempt lifecycle, retry tax,
   attribution, summary KPIs).

When ending a session, update only this handoff summary and next step.
Put detailed historical notes in `CHANGELOG.md`, release matrices in
`koder/releases/`, and issue-specific detail in the relevant issue or
plan file.
