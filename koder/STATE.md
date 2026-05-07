# Harnex State

Updated: 2026-05-07

This is a thin handoff document. Keep it limited to past / present /
future context for the next session. Durable change history belongs in
`CHANGELOG.md`; release verification belongs in `koder/releases/`;
implementation detail belongs in `koder/issues/` or `koder/plans/`.

## Past

- 2026-05-07: `koder/STATE.md` was slimmed into this handoff format.
  `CLAUDE.md` and the repo-local `open` / `close` skills now instruct
  future sessions to keep STATE thin. See `CHANGELOG.md` Unreleased.
- `harnex 0.6.5` shipped and was verified end-to-end on 2026-05-07.
  See `CHANGELOG.md` and `koder/releases/0.6.5.md` for release and
  verification details.
- Latest verified suite at release time: 396 runs, 1220 assertions, 0
  failures, 1 skip (`CODEX_INTEGRATION=1` gate).
- The latest release included the JSON-RPC release-blocker pair:
  token usage capture in `DISPATCH.jsonl` (#33) and early rejection of
  unsupported JSON-RPC model flags (#34). It also included JSON-RPC
  stop subprocess teardown (#31) and one-shot `--auto-stop` (#15).
- A post-release quality audit surfaced two unfiled follow-up areas:
  concurrency / hardening, and doc staleness. The detailed notes are in
  `koder/releases/0.6.5.md`.

## Present

- Codex uses the JSON-RPC `app-server` transport by default. PTY remains
  a first-class transport for visible TUI sessions and non-JSON-RPC
  adapters.
- Current tracked focus: `koder/issues/35_dispatch_telemetry_hygiene.md`
  (P2, open).
- Best contained starting point: #35 Tier 1. Add already-captured fields
  to the DISPATCH row, stabilize conditional keys, and add a regression
  test for row shape.
- Other open issues to revisit after #35 or triage:
  - #04 Output streaming
  - #06 Full adapter abstraction
  - #16 Platform-agnostic data directory
  - #17 Multi-session coordination
  - #18 Buddy pattern
  - #26 `harnex status` repo filtering
- Test command:
  `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`

## Future

1. Land #35 Tier 1 as a focused bugfix commit.
2. File the concurrency / hardening audit findings as a new issue, then
   triage implementation priority.
3. File the doc-staleness audit findings as a new issue, then refresh
   the stale docs.

When ending a session, update only this handoff summary and next step.
Put detailed historical notes in `CHANGELOG.md`, release matrices in
`koder/releases/`, and issue-specific detail in the relevant issue or
plan file.
