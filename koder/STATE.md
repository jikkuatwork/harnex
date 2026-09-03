# Harnex State

Updated: 2026-09-03 | 08:04 AM | IST

This is the thin session handoff. Durable history belongs in `CHANGELOG.md`,
release evidence in `koder/releases/`, and implementation detail in linked
issue/plan files.

## Past

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

- `koder/plans/35_completion_push_signals.md` is drafted for the first bounded
  #71 slice: session-owned completion markers, one unified `--on-done` hook,
  and loud rejected-work visibility. **Reviewed 2026-09-03 and approved with
  corrections** (observed-unsuccessful-completion classification row; top-level
  `status` stays `completed` for rejected work; orchestrator-wake file-trigger
  note). No implementation has started; heartbeat and hard-deadline work remain
  deferred within #71.
- RubyGems and the local executable report `0.11.0`. `main` has the unpushed
  #71 issue commit (`74b69a9`); the plan/issue/handoff edits land with this
  close.
- #69 still blocks persistent Pi reuse; fresh `--auto-stop` workers remain the
  safe lifecycle. #58 remains explicitly unsupported, and the registry
  lost-update race remains known.

## Future

1. Implement Plan 35's core push-signal slice (plan reviewed 2026-09-03,
   approved with corrections); stop after focused/full tests, the no-watcher
   smoke, and independent review.
2. Fix #69 before persistent Pi worker reuse.
3. Plan the remaining #71 heartbeat/deadline slices, then implement #56 adapter
   preflight and #70 Pi command-exit evidence.
4. Converge #57/#59 into the deterministic conveyor; #45, #42 / Plan 30, #41,
   and #58 remain later bounded work.
