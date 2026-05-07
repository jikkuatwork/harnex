# Harnex State

Updated: 2026-05-07 | 05:59 PM | IST

This is a thin handoff document. Keep it limited to past / present /
future context for the next session. Durable change history belongs in
`CHANGELOG.md`; release verification belongs in `koder/releases/`;
implementation detail belongs in `koder/issues/` or `koder/plans/`.

## Past

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
- Tree is clean on `main` after #36 Tier 2 ships. CHANGELOG
  `[Unreleased]` carries the entry under `### Fixed`.
- #35 Tier 2/3/4 still open under `koder/issues/35_*` as
  follow-ups (turn counts, log paths, richer captures).
- Other open issues to triage when ready: #04, #06, #16, #17,
  #18, #26.
- Test command:
  `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`

## Future

1. #35 Tier 2: extend DISPATCH telemetry per the issue's tier
   plan (turn counts, log paths). See
   `koder/issues/35_dispatch_telemetry_hygiene.md`.
2. Optional #36 follow-ups (deferred — not required for closure):
   add `wait --until row_emitted` predicate; bump event timestamps
   to `iso8601(3)` so future regressions can be quantified directly
   from the events log.
3. File the concurrency / hardening audit and the doc-staleness
   audit findings from `koder/releases/0.6.5.md` as new issues.

When ending a session, update only this handoff summary and next step.
Put detailed historical notes in `CHANGELOG.md`, release matrices in
`koder/releases/`, and issue-specific detail in the relevant issue or
plan file.
