# Harnex State

Updated: 2026-05-07 (later)

This is a thin handoff document. Keep it limited to past / present /
future context for the next session. Durable change history belongs in
`CHANGELOG.md`; release verification belongs in `koder/releases/`;
implementation detail belongs in `koder/issues/` or `koder/plans/`.

## Past

- 2026-05-07: #36 Tier 1 diagnosis logged on
  `koder/issues/36_autostop_dispatch_row_race.md`. Race is
  architectural — `harnex wait` (default) polls subprocess pid;
  the DISPATCH row is written in the harnex parent's
  `finalize_session!` *after* `Process.wait2` unblocks, so wait
  can return between subprocess death and row append. The
  observed cx-d-readme gap was sub-second per the events log.
  Recommended fix: `Waiter#wait_until_exit` should poll
  `exit_status_path` (written after `finalize_session`) with a
  bounded grace before returning.
- 2026-05-07: #35 Tier 1 (DISPATCH telemetry hygiene) landed.
  Schema regression test in place. Suite green earlier today.
- `harnex 0.6.5` shipped and verified — see `CHANGELOG.md` and
  `koder/releases/0.6.5.md`.

## Present

- Codex uses JSON-RPC `app-server` by default; PTY remains
  first-class for visible TUI and non-JSON-RPC adapters.
- #36 is at the Tier 2 boundary: diagnosis + fix recommendation
  are written into the issue; nothing has been implemented yet.
- #35 Tier 2/3/4 still open under `koder/issues/35_*` as
  follow-ups (turn counts, log paths, richer captures).
- Other open issues to triage when ready: #04, #06, #16, #17,
  #18, #26.
- Test command:
  `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`

## Future

1. Implement #36 Tier 2: bound `harnex wait` to the DISPATCH row
   write. Smallest correct shape per the issue's "Tier 2 —
   recommended fix" section: in `Waiter#wait_until_exit`
   (`lib/harnex/commands/wait.rb`), when `alive_pid?` flips false,
   poll `exit_status_path` with a ~5s grace before falling back
   to a synthesized `exited` response. Add a regression test that
   asserts the DISPATCH row is on disk by the time `wait` returns.
2. Optional follow-ups noted on #36: explicit
   `wait --until row_emitted` predicate; bump events log
   timestamps to `iso8601(3)` so future regressions can be
   measured directly.
3. After #36 Tier 2 lands, return to #35 Tier 2.
4. File the concurrency / hardening audit and the doc-staleness
   audit findings from `koder/releases/0.6.5.md` as new issues.

When ending a session, update only this handoff summary and next step.
Put detailed historical notes in `CHANGELOG.md`, release matrices in
`koder/releases/`, and issue-specific detail in the relevant issue or
plan file.
