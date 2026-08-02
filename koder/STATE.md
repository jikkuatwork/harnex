# Harnex State

Updated: 2026-08-02 | 08:52 PM | IST

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

- No active blocker. Suite green at `v0.8.0` (573 runs, 0 failures, 2
  env-gated skips) including the schema-drift gate, no skip flag needed.
- Known cosmetic nit (pre-existing): `harnex history` renders a blank row
  for 2026-05-era `{meta, predicted, actual}`-schema rows in
  `.harnex/dispatch.jsonl`. Details in `koder/releases/0.8.0.md`; not filed
  as an issue — ask the user before filing/fixing.
- #63 (single tracked telemetry stream), #64 (observed-state receipts), and
  #57 (terminal-outcome vocabulary + failure budget) remain filed and open.
- #42 (Codex app-server recovery) and #43 (throughput telemetry v2) remain
  open; plan 30 Phases 3–5 still own live fallback production.

## Future

1. #63 — single versioned tracked telemetry stream (subsumes #58 cost gap).
2. #64 — observed-state receipts (harness-authored proof).
3. Implement #56 adapter preflight using strict proof acceptance, then
   continue #57's remaining outcome classes and failure-budget rollup —
   converging with #59 into the deterministic queue runner (Holm plan 708.S04).
4. #45 — implement Pi PTY/TUI support only behind stable extension markers.
5. #42 / plan 30 Phases 3–5 — resume structured recovery and fallback work.
6. #41 Slice C — document the public API in `docs/public_api.md`.
