# Harnex State

Updated: 2026-05-07

This is a thin handoff document. Keep it limited to past / present /
future context for the next session. Durable change history belongs in
`CHANGELOG.md`; release verification belongs in `koder/releases/`;
implementation detail belongs in `koder/issues/` or `koder/plans/`.

## Past

- 2026-05-07: #35 Tier 1 (DISPATCH telemetry hygiene) landed via
  TDD-dispatched codex worker + independent reviewer. New schema
  regression test asserts full row key set + types. Suite: 398 runs,
  1288 assertions, 0 failures, 1 skip.
- 2026-05-07: README refreshed to reflect Codex JSON-RPC default,
  `--auto-stop`, `harnex doctor`, and current `--id`/`--tmux` rules.
- 2026-05-07: New conventions captured in `CLAUDE.md`:
  worker-id naming (`cx-<role>-<issue|tag>`), monotonic plan
  numbering with "layer" grouping, and `koder/DISPATCH.jsonl` is
  durable telemetry — never `git checkout` it.
- 2026-05-07: `.claude/skills/open` updated with token discipline
  (only read the issue STATE points to; meta-list the rest).
- `harnex 0.6.5` shipped and was verified end-to-end earlier today.
  See `CHANGELOG.md` and `koder/releases/0.6.5.md`.

## Present

- Codex uses JSON-RPC `app-server` by default; PTY remains
  first-class for visible TUI and non-JSON-RPC adapters.
- Current tracked focus:
  `koder/issues/36_autostop_dispatch_row_race.md` (P3, open) —
  observed during this session: `--auto-stop` workers leave the
  session in `disconnected` for tens of seconds *after* the
  task-complete signal, before the row lands in
  `koder/DISPATCH.jsonl`. Race window can fool reviewers into
  reading stale telemetry.
- #35 Tier 2/3/4 remain open under the same issue file as
  follow-ups (turn counts, log paths, populate-vs-remove decisions,
  richer captures).
- Other open issues to revisit after #36 or triage:
  - #04 Output streaming
  - #06 Full adapter abstraction
  - #16 Platform-agnostic data directory
  - #17 Multi-session coordination
  - #18 Buddy pattern
  - #26 `harnex status` repo filtering
- Test command:
  `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`

## Future

1. Diagnose #36 — repro the race deterministically on PTY and
   JSON-RPC; time the gap from done-signal → row-on-disk; decide
   between earlier emission, a new `wait --until row_emitted`
   barrier, or making `harnex wait` row-aware.
2. After #36 lands, return to #35 Tier 2 (turn/message counts,
   log paths, auto-derived `parent_dispatch_id`).
3. File the concurrency / hardening audit and the doc-staleness
   audit findings from `koder/releases/0.6.5.md` as new issues.

When ending a session, update only this handoff summary and next step.
Put detailed historical notes in `CHANGELOG.md`, release matrices in
`koder/releases/`, and issue-specific detail in the relevant issue or
plan file.
