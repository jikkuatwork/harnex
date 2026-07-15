# Harnex State

Updated: 2026-07-15 | IST

This is the thin session handoff. Durable history belongs in `CHANGELOG.md`,
release evidence in `koder/releases/`, and implementation detail in the linked
issue/plan files.

## Past

- 2026-07-15 | IST: #56–#59 filed from the SDK repo's Queue `#002` overnight
  run post-mortem (`~/Projects/holmhq/sdk/koder/analysis/001_.../INDEX.md`):
  adapter preflight dispatch smoke (#56), terminal outcome classes plus a
  run-scoped process-failure budget (#57), Claude adapter usage/cost/context
  capture (#58), and a deterministic conveyor runner track (#59). Filed only;
  no code changed.
- 2026-07-12 | 05:55 PM | IST: #54 active context-window pressure telemetry
  implemented and closed (unreleased) via
  `koder/plans/32_context_window_pressure_telemetry.md`. Dispatch rows now have
  a stable `context` block: Pi supplies observed terminal/high-water samples,
  Codex supplies conservative estimates, and compaction-null/missing/
  unsupported states remain explicit. Implementation commit: `ec05ed0`.
  Full suite: 524 runs, 2012 assertions, 0 failures, 2 skips.
- 2026-07-11 | 11:26 PM | IST: Plan 31 implemented the #46 cost/usage
  provenance follow-up (unreleased): additive usage/attribution/outcome/attempt
  blocks and lifecycle events. #43 remains open for the real #42/plan-30
  recovery/fallback producer. See
  `koder/plans/31_telemetry_provenance_and_outcomes.md`.
- 2026-07-10 | 11:25 PM | IST: `harnex 0.7.12` shipped and was installed
  locally. Verification: `koder/releases/0.7.12.md`.

## Present

- `main` contains unreleased plan-31 telemetry foundations and #54 context
  pressure telemetry. Installed `harnex` on `PATH` remains `0.7.12` and does
  **not** include these unreleased changes.
- #55 is the next telemetry slice: define logical primary-orchestrator
  generations and queue-level primary-versus-worker orchestration-tax rollups.
- #42 (Codex app-server recovery) and #43 (throughput telemetry v2 integration)
  remain open; plan 30 Phases 3–5 still own live fallback production.
- The SDK's Queue `#002` run (14–15 Jul) exposed the operational gaps behind
  #56–#59: it ran on installed `0.7.12` without the unreleased provenance/
  context telemetry, its Claude workers were productive but telemetry-blind,
  and ~49% of accounted tokens went to a coordinator doing mechanical work.
- Test command:
  `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`

## Future

1. Release the accumulated plan-31 + #54 telemetry as `0.7.13` before the SDK
   Queue `#002` recovery run, so that run is measured with provenance.
2. #56 preflight and #57 outcome classes are the highest-leverage small slices
   from the Queue `#002` post-mortem; #58 closes the largest per-adapter
   telemetry hole; #59 is a design track, plan first.
3. #55 — design primary-orchestrator generation and orchestration-tax telemetry.
3. #45 — implement Pi PTY/TUI support only behind stable extension markers.
4. #42 / plan 30 Phases 3–5 — resume structured recovery and fallback work.
5. #41 Slice C — document the public API in `docs/public_api.md`.
6. #43 — connect plan 31's attempt-transition seam to real recovery/fallback
   producers, then add live retry/disconnect/fallback economics coverage.
