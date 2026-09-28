# Harnex State

Updated: 2026-09-28 | 04:46 PM | +04

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

- **`harnex 0.13.0` is installed locally** from candidate commit `bf60266`
  under an explicit owner exception that defers public publication. It combines
  owner-addressed completion with Issue #73's archive bridge and `c2e5510`'s
  protocol-1 capability probe. Verification: `koder/releases/0.13.0.md`.
- The exact retained gem is 184,832 bytes with SHA-256
  `2a8d8bfd2d852998772cd973c2d9c19346282617b29920055f8caadd74921268`.
  Full suite: 714 runs / 3,077 assertions. An installed-binary synthetic writer/
  reader smoke produced two real-age local archives, reconstructed all nine
  records exactly, and passed canonical validation.
- Published `0.12.0` and locally installed `0.12.1` remain available as rollback.
  Issue #72 remains open as public-release tracking. No archive hook is globally
  enabled and no live telemetry moved.
- Public publication is deferred because prescribed `bin/gem-push` still cannot
  find `.env`. No credential workaround, tag, Git push, or network publication
  occurred.
- #71 remains open for heartbeat/hard-deadline slices. A 2026-09-28 source audit
  records the next bounded scope: genuine model/tool activity versus UI/log age,
  typed stop provenance, then a runner-owned runtime budget distinct from a
  watch timeout. These are proposals, not implemented or installed behavior.
  Consumer-side stale/visible wake suppression belongs in the Pi bridge, not
  another Harnex queue. #69 still blocks persistent Pi reuse; fresh
  `--auto-stop` workers remain the safe lifecycle.

## Future

1. When public publication is desired, restore `.env` and publish the exact
   retained `harnex-0.13.0.gem`; do not rebuild version 0.13.0. Then tag/push
   `bf60266`, update the release record, and resolve #72.
2. Holm may consume the installed archive protocol after its remaining recipient
   proofs; keep both helper environment variables unset until Holm activates it.
3. Fix #69 before persistent Pi worker reuse, then continue #71/#56/#70.
