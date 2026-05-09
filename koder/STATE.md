# Harnex State

Updated: 2026-05-09 | 09:25 PM | IST

This is a thin handoff document. Keep it limited to past / present /
future context for the next session. Durable change history belongs in
`CHANGELOG.md`; release verification belongs in `koder/releases/`;
implementation detail belongs in `koder/issues/` or `koder/plans/`.

## Past

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

- Codex uses JSON-RPC `app-server` by default; PTY remains
  first-class for visible TUI and non-JSON-RPC adapters.
- Tree is expected clean on `main` after the #39 commit. CHANGELOG
  `[Unreleased]` carries #37, #38, and #39; no release has been cut.
- Local unskipped `bundle exec rake test` currently fails only
  `SchemaFreshnessTest` because the installed Codex app-server schemas
  drifted from fixtures; `HARNEX_SKIP_SCHEMA_DRIFT=1 bundle exec rake
  test` is green.
- #35 Tier 1/2/3 all resolved. Tier 4 (`commit_shas`, `branch_end`)
  remains optional.
- Other open issues to triage when ready: #04, #06, #16, #17,
  #18, #26.
- Test command:
  `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`

## Future

1. Release/verify the F21 + #37 + #38 + #39 changes with the next gem
   cut when release is explicitly requested.
2. Refresh or triage the Codex app-server schema fixture drift tracked
   by `SchemaFreshnessTest` before requiring an unskipped local suite.
3. #35 deferred `auto_disconnects` — needs a dedicated counter
   (likely "auto-resumed disconnects") rather than the current
   alias-of-disconnections shape. Tracked in the issue file.
4. Optional #36 follow-ups (deferred — not required for closure):
   add `wait --until row_emitted` predicate; bump event timestamps
   to `iso8601(3)` so future regressions can be quantified directly
   from the events log.
5. File the concurrency / hardening audit and the doc-staleness
   audit findings from `koder/releases/0.6.5.md` as new issues.
6. #35 Tier 4 (optional): `commit_shas: [...]` list and `branch_end`
   capture if/when richer git context is wanted.

When ending a session, update only this handoff summary and next step.
Put detailed historical notes in `CHANGELOG.md`, release matrices in
`koder/releases/`, and issue-specific detail in the relevant issue or
plan file.
