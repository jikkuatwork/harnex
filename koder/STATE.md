# Harnex State

Updated: 2026-08-02 | 05:35 PM | IST

This is the thin session handoff. Durable history belongs in `CHANGELOG.md`,
release evidence in `koder/releases/`, and implementation detail in the linked
issue/plan files.

## Past

- 2026-07-15 | 10:12 PM | IST: `harnex 0.7.14` shipped, was pushed/tagged, and
  was installed locally. It releases #55 orchestration-tax telemetry and closes
  #60/#61 with proof-aware Codex completion, strict artifact-report acceptance,
  and report init/validation tooling. Verification:
  `koder/releases/0.7.14.md`.
- Release suite at `v0.7.14` / `0c3c996`: 552 runs, 2208 assertions,
  0 failures, 2 skips. Installed strict-report, acknowledgment-only Codex,
  orchestration, and doctor smokes passed.

## Present

- 2026-08-02: **#62–#64 filed from Holm's Q096 forensics** (Holm plan
  `koder/plans/708_S00_process_mechanization_mapping/INDEX.md`). Holm Queue
  096 blocked itself because live dispatches are invisible mid-run
  (`status`/`history`/`wait` all read a healthy worker as dead) and a
  coordinator dispatched three duplicate workers. **#62 is the next
  execution target and is fully self-contained** (timeline, code anchors,
  acceptance scenario). #63 unifies telemetry into one versioned tracked
  stream (subsumes #58's cost gap); #64 makes receipts harness-generated
  from observed state. The broader Holm program then lands #57/#59 as the
  deterministic queue runner.
- `main`, RubyGems, the `v0.7.14` tag, and the local `harnex` on `PATH` all
  carry the released proof-acceptance work.
- #57 remains open for the broader terminal-outcome vocabulary, correlated
  failure families, rollup, and process-failure budget; 0.7.14 supplies only
  the #60/#61 proof subset.
- #42 (Codex app-server recovery) and #43 (throughput telemetry v2 integration)
  remain open; plan 30 Phases 3–5 still own live fallback production.
- Test command:
  `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`

## Future

1. **#62 — live-run observability + duplicate-dispatch guard (P1).** Start
   records, live `status`/`history`/`wait` visibility, wait exit-code
   contract, refuse-retry-while-parent-alive. Gate for Holm's queue relaunch.
2. #63 — single versioned tracked telemetry stream (subsumes #58 cost gap).
3. #64 — observed-state receipts (harness-authored proof).
4. Implement #56 adapter preflight using 0.7.14 strict proof acceptance, then
   continue #57's remaining outcome classes and failure-budget rollup —
   converging with #59 into the deterministic queue runner (Holm plan 708.S04).
5. #45 — implement Pi PTY/TUI support only behind stable extension markers.
6. #42 / plan 30 Phases 3–5 — resume structured recovery and fallback work.
7. #41 Slice C — document the public API in `docs/public_api.md`.
