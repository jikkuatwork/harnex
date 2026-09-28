# Harnex State

Updated: 2026-09-28 | 09:31 PM | +04

Thin session handoff. History: `CHANGELOG.md`; release evidence:
`koder/releases/`; implementation detail: linked issues/plans.

## Past

- **0.14.0 is built, installed locally, and verified on PATH** from package
  source `aab0973`. #69 and #71 are resolved; Plans 36–38 are complete.
  Full suite: 815 runs / 3,820 assertions / no failures or errors; independent
  review approved. Evidence and explicit non-coverage: `koder/releases/0.14.0.md`.
- Installed Pi 0.87.1 live checks passed: two accepted turns followed by idle
  stop preserve proof; a 30s runtime cap stops active tool work with typed
  provenance and no false disconnection. All task dispatch rows are retained.
- Pi `open`/`close` discovery was restored through repo-local skill links.
  Published 0.12.0 and local 0.13.0/0.12.1 remain available as rollback.

## Present

- **Local-only release.** No RubyGems push, tag, Git push, or public source
  publication occurred. The exact ignored `harnex-0.14.0.gem` is retained;
  its identity is in the release record. Do not rebuild version 0.14.0.
- `run --max-runtime` is opt-in and independent of observer `--max-wait`.
  Doctor exposes versioned capabilities. Work clocks exclude UI/log freshness;
  stop labels and actual runtime enforcement are distinct.
- The cap terminates owned process groups, not deliberately escaped sessions;
  finalization can still wait on local I/O. Pi command-exit observation remains
  unsupported (#70). Notifications are once per session: verify each reused
  turn's receipt/artifacts, not an old completion marker. Fresh workers remain
  the default, not a mandatory #69 workaround.
- No archive hook was globally enabled and no live telemetry was trimmed.
  The retained 0.13.0 gem is unchanged; #72 still tracks public publication.

## Future

1. Consumers may adopt the new controls after `doctor --adapter pi` capability
   checks; retain exact-receipt/artifact verification and owner acknowledgment.
2. Continue #70 (Pi command-exit observation), then #56 and the remaining backlog.
3. Publish only when separately authorized, using the verified retained artifact
   and the repository release procedure; public-release tracking remains #72.
