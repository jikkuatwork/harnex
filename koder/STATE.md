# Harnex State

Updated: 2026-09-19 | 12:50 PM | +04

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

- Issue #73's opt-in archive bridge landed at `011f186`: stable sidecar locking
  protects atomic ledger replacement, while configured local helpers prepare
  appends and provide complete archive-plus-active history to Harnex readers.
  The full suite passed `712` runs / `3,072` assertions. No hook is globally
  enabled, no telemetry moved, and no release was cut.
- `0.12.1` owner-addressed completion delivery is implemented at `a532a5b` and
  accepted: full suite `706/3051`, exact candidate gem package check, and
  offline Pi smokes for completion, failure, and native watcher recovery pass.
- Under explicit owner direction, the exact gem is globally selected as local
  `0.12.1`; published `0.12.0` remains installed as rollback. The global
  executable repeated all three smokes with zero residual sessions, so local
  runtime use is unblocked. Issue #72 remains open only as release tracking.
- Public publication is deferred because prescribed `bin/gem-push` cannot find
  its required `.env`. No credential workaround, tag, or Git push occurred.
- #71 remains open for heartbeat/hard-deadline slices. #69 still blocks
  persistent Pi reuse; fresh `--auto-stop` workers remain the safe lifecycle.

## Future

1. When public publication is desired, restore the release `.env`, publish the
   already verified `harnex-0.12.1.gem`, tag/push `a532a5b`, write the release
   record, and resolve #72. Do not rebuild a different package under 0.12.1.
2. Fix #69 before persistent Pi worker reuse.
3. Plan the remaining #71 heartbeat/deadline slices, then implement #56 adapter
   preflight and #70 Pi command-exit evidence.
4. Release the #73 archive bridge in a later version only when Holm's archive
   activation is cleared; keep both helper environment variables unset until then.
