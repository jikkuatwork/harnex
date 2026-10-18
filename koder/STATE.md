# Harnex State

Updated: 2026-10-18 | 02:35 AM | IST

Thin session handoff. History: `CHANGELOG.md`; release evidence:
`koder/releases/`; implementation detail: linked issues/plans.

## Past

- **0.16.0 is installed locally and verified on PATH** from `6602912`.
  #68 final gates (`--final-gate`, `validation.final_gates`,
  `commands_had_failures`); #57 process outcome classes + `orchestration
  report` class/family rollup and `--failure-budget` (exit 3); #56
  `harnex preflight ADAPTER` (JSON verdict, `phase=preflight` rows); #26 status
  cross-repo hint; #49 bare-wait notes; millisecond event `ts`.
  Suite: 887 runs / 4,199 assertions, no failures. Live Pi preflight passes
  (checkout and installed CLI). Details and non-coverage:
  `koder/releases/0.16.0.md`.
- Tracker triage closed stale #04 #06 #30 #33 #34 #35 #36 #37 and #72.
- 0.15.0 and earlier gems remain installed as rollback.

## Present

- **Owner decision 2026-10-18: local installs only, no RubyGems publication.**
  Release = suite green → `gem build` → `gem install --local` → smoke →
  release record; skip `bin/gem-push`, tag and push.
- **Codex is deferred (owner, 2026-10-18): no longer used.** Its local API key
  returns 401; do not spend effort on Codex verification or Codex-only work.
  Pi is the dispatch adapter.
- Pi is **1.3.0** (`pi update` says current). Run `pi update` before Pi work.
- The `harnex` mise shim needs a directory with a Ruby version (run from a
  project dir; pass `--cwd` for scratch repos).

## Future

1. Owner decisions unblock the rest: #76 (`watch --stall-after` clock, PTY
   behavior, exit code) then #77 (owner-scoped event stream contract for Holm
   Claude Code supervisors, depends on #76).
2. Holm can adopt `harnex preflight` before unattended queues and
   `--final-gate` for receipt diagnostics (check `capabilities.preflight` /
   `final_gates`).
3. Remaining open issues need product calls (#16, #17, #40, #41 Slice C, #42,
   #58, #59) or are blocked (#43 on #42; #45 deferred).
