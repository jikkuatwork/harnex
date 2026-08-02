# Harnex State

Updated: 2026-08-02 | 11:20 PM | IST

This is the thin session handoff. Durable history belongs in `CHANGELOG.md`,
release evidence in `koder/releases/`, and implementation detail in the linked
issue/plan files.

## Past

- 2026-08-02 | 08:52 PM | IST: **`harnex 0.8.0` shipped** (pushed, tagged
  `v0.8.0`, installed locally — `harnex --version` verified): #62 live-run
  observability + duplicate-dispatch guard, plus the codex schema fixture
  refresh against codex-cli 0.145.0 (drift reviewed: additive only, no
  adapter impact). Verification: `koder/releases/0.8.0.md`. This unblocks
  Holm's queue relaunch (Q096 gap closed, plan 708).
- 2026-07-15 | 10:12 PM | IST: `harnex 0.7.14` shipped: #55
  orchestration-tax telemetry, #60/#61 proof-aware completion.
  Verification: `koder/releases/0.7.14.md`.

## Present

- No active blocker. Suite green at HEAD (576 runs, 0 failures, 2
  env-gated skips).
- 2026-08-02 | 11:20 PM | IST: **Plan 33 Phase 1 implemented**
  (unreleased): unified v2 `dispatch_end` row (envelope + rich sections),
  exactly two rows per dispatch on the canonical
  `DispatchHistory.path_for` stream, `--summary-out` demoted to
  explicit-only mirror, `default_summary_out_path` deleted,
  `TerminalStatus` resolves v2 rows for `wait`/`status`. CHANGELOG
  Unreleased has the details; phases 2–7 remain.
- `harnex history` blank-row fix also unreleased (`591e59b`).
- #64 (observed-state receipts) and #57 (terminal-outcome vocabulary +
  failure budget) remain filed and open.
- #42 (Codex app-server recovery) and #43 (throughput telemetry v2) remain
  open; plan 30 Phases 3–5 still own live fallback production.

## Future

1. **Next: plan 33 Phase 2** (price-table cost for token-reporting
   adapters — `lib/harnex/pricing.rb`, wired into `build_summary_usage`;
   verify Codex token semantics against the schema fixtures first). Then
   Phase 3 (Claude usage producer, separable) and Phases 4–7. Release
   Phase 1 + migration note together so Holm flips `--summary-out` off
   exactly once (plan 33 “Risks and guards”).
2. #64 — observed-state receipts (harness-authored proof).
3. Implement #56 adapter preflight using strict proof acceptance, then
   continue #57's remaining outcome classes and failure-budget rollup —
   converging with #59 into the deterministic queue runner (Holm plan 708.S04).
4. #45 — implement Pi PTY/TUI support only behind stable extension markers.
5. #42 / plan 30 Phases 3–5 — resume structured recovery and fallback work.
6. #41 Slice C — document the public API in `docs/public_api.md`.
