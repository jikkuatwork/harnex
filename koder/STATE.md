# Harnex State

Updated: 2026-09-03 | 10:16 AM | IST

This is the thin session handoff. Durable history belongs in `CHANGELOG.md`,
release evidence in `koder/releases/`, and implementation detail in linked
issue/plan files.

## Past

- 2026-09-03 | 10:15 AM | IST: **`harnex 0.12.0` shipped** (`b41ee9d`,
  `v0.12.0`). Plan 35's core #71 slice adds typed default completion markers,
  `run --on-done` across foreground/detached/tmux, first-terminal race safety,
  and settled-state table precedence. Full suite: 702 runs, 3,037 assertions,
  0 failures; independent review approved; published, pushed, installed, and
  live-smoked with Pi 0.84.4. Verification: `koder/releases/0.12.0.md`.
- 2026-08-14 | 01:10 PM | IST: **`harnex 0.11.0` shipped** (`84237b7`,
  `v0.11.0`). Pi >= 0.80.4 now completes only at `agent_settled`; Pi 0.84
  delta streams, typed terminal failures, verified model/thinking startup
  policy, steering sends, bounded RPC waits/stderr, and real child status are
  production-hardened. `harnex doctor --adapter pi` and `docs/pi-rpc.md` expose
  the contract. Full suite green (689 runs), published to RubyGems, pushed,
  installed locally, and live-smoked against Pi 0.84.1. Verification:
  `koder/releases/0.11.0.md`.
- The release gate's Codex 0.147.0 schema drift received only a bounded semantic
  review: one string path alias plus additive optional fields not consumed by
  Harnex. Refreshed fixtures and existing Codex contracts pass; no runtime
  Codex behavior changed.
- 2026-08-08 | 06:52 PM | IST: **`harnex 0.10.2` shipped** (`ef25148`,
  `v0.10.2`), correcting monitoring guidance for harness-owned telemetry.

## Present

- RubyGems and the local executable report `0.12.0`; Holm can now consume
  `--on-done` and the session-owned marker contract.
- #71 remains open only for separately planned heartbeat and hard-deadline
  slices. No polling/deadline behavior changed in Plan 35.
- #69 still blocks persistent Pi reuse; fresh `--auto-stop` workers remain the
  safe lifecycle. #58 remains explicitly unsupported, and the registry
  lost-update race remains known.

## Future

1. Wire Holm's `--on-done` hook to its gitignored
   `koder/scratch/HARNEX_WAKE.txt` trigger and verify the consumer wake path.
2. Fix #69 before persistent Pi worker reuse.
3. Plan the remaining #71 heartbeat/deadline slices, then implement #56 adapter
   preflight and #70 Pi command-exit evidence.
4. Converge #57/#59 into the deterministic conveyor; #45, #42 / Plan 30, #41,
   and #58 remain later bounded work.
