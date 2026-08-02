# Harnex State

Updated: 2026-08-02 | 08:37 PM | IST

This is the thin session handoff. Durable history belongs in `CHANGELOG.md`,
release evidence in `koder/releases/`, and implementation detail in the linked
issue/plan files.

## Past

- 2026-08-02 | 06:52 PM | IST: **#62 implemented on `main` (unreleased)** —
  dispatch-start records, live `status`/`history`/`wait` visibility with
  degraded-source labelling, the `wait --until done` exit-code contract
  (0/1/2/3/124, documented in `guides/04_monitoring.md`), and the
  duplicate-dispatch guard (`--allow-live-parent` override). Q096 acceptance
  test: `test/integration/live_run_observability_test.rb`. Details in the
  issue's Resolution section and `CHANGELOG.md` [Unreleased].
- 2026-07-15 | 10:12 PM | IST: `harnex 0.7.14` shipped (pushed/tagged/installed
  locally): #55 orchestration-tax telemetry, #60/#61 proof-aware completion.
  Verification: `koder/releases/0.7.14.md`.

## Present

- #62 closes the Q096 gap from Holm plan
  `koder/plans/708_S00_process_mechanization_mapping/INDEX.md` (live
  dispatches invisible mid-run; coordinator dispatched duplicate workers).
  The work is on `main` but **not yet released** — Holm's queue relaunch
  needs a gem release + local `gem install` to pick it up.
- Behavior changes to note for release notes: `wait --until done` no longer
  passes the child's exit code through (fixed contract codes now);
  `--attempt-kind retry` now requires `--parent-dispatch-id`.
- #63 (single tracked telemetry stream) and #64 (observed-state receipts)
  remain filed and self-contained; #57 remains open for the broader
  terminal-outcome vocabulary and failure budget.
- #42 (Codex app-server recovery) and #43 (throughput telemetry v2 integration)
  remain open; plan 30 Phases 3–5 still own live fallback production.
- **Pre-existing, unrelated to #62:** the codex schema-drift gate
  (`test/harnex/contract/schema_freshness_test.rb`) fails against the
  locally-updated codex CLI (10 fixtures drifted, e.g.
  `v2/TurnStartedNotification.json`). Refresh fixtures per the test's
  instructions before the next release, or run the suite with
  `HARNEX_SKIP_SCHEMA_DRIFT=1` in the meantime.
- Test command:
  `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`

## Future

1. **Refresh the drifted codex schema fixtures, then release #62** as the
   next gem version (follow the release checklist in `CLAUDE.md`, including
   local `gem install`) — gate for Holm's queue relaunch. The suite must be
   green *without* `HARNEX_SKIP_SCHEMA_DRIFT=1` before tagging; the drift
   test's failure message gives the exact `codex app-server
   generate-json-schema` + `cp` refresh steps per fixture. If any refreshed
   schema implies adapter changes, file an issue instead of blind-copying.
2. #63 — single versioned tracked telemetry stream (subsumes #58 cost gap).
3. #64 — observed-state receipts (harness-authored proof).
4. Implement #56 adapter preflight using 0.7.14 strict proof acceptance, then
   continue #57's remaining outcome classes and failure-budget rollup —
   converging with #59 into the deterministic queue runner (Holm plan 708.S04).
5. #45 — implement Pi PTY/TUI support only behind stable extension markers.
6. #42 / plan 30 Phases 3–5 — resume structured recovery and fallback work.
7. #41 Slice C — document the public API in `docs/public_api.md`.
