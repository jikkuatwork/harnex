# Harnex State

Updated: 2026-08-14 | 06:48 PM | IST

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

- Nothing is in flight. RubyGems and the local executable report `0.11.0`;
  `main` and `v0.11.0` are pushed and synchronized.
- Holm Q121 filed external findings #69 and #70: idle explicit stop can rewrite
  accepted Pi proof as failure, and Pi receipts lack bash command/exit
  observation. Fresh `--auto-stop` Pi workers remain proven safe.
- #58 remains explicitly unsupported. The known cross-process registry
  lost-update race remains: writes are atomic, but stale fields are possible.

## Future

1. Triage #69 before persistent Pi worker reuse; keep `--auto-stop` as the safe
   lifecycle. Then scope #70 for adapter-neutral receipt/final-gate proof.
2. Implement #56 adapter preflight, then converge #57/#59 into the deterministic
   conveyor runner required by Holm Plan 708.S04.
3. #45 Pi PTY stable markers, then #42 / Plan 30 recovery/fallback phases.
4. Broader Codex 0.147 runtime review can remain separate; #41 API docs and #58
   Claude usage follow when prioritized and bounded.
