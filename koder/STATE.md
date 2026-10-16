# Harnex State

Updated: 2026-10-16 | 07:05 AM | +04

Thin session handoff. History: `CHANGELOG.md`; release evidence:
`koder/releases/`; implementation detail: linked issues/plans.

## Past

- **#70 and #75 resolved on `main`, unreleased** (CHANGELOG `[Unreleased]`).
  #70: Pi RPC receipts attest bash command text + integer exits from
  `structuredContent.exit_code`; missing evidence fails closed via
  `command_observation: partial|unsupported` and `observed.commands_unobserved`.
  #75: `wait`/`watch` no longer die when a sibling registry vanishes mid-scan.
  Full suite: 834 runs / 3,913 assertions / no failures or errors / three
  opt-in skips; `PI_INTEGRATION=1` passes on Pi 1.3.0; live `harnex run pi`
  receipt verified. Detail: the two issue files' Resolution sections.
- **0.14.1 is installed locally** from `c835a93` (#74); record:
  `koder/releases/0.14.1.md`. 0.14.0/0.13.0 gems retained as rollback.

## Present

- **Installed CLI is still 0.14.1** — neither fix is live for Holm queues until
  a local release is cut and installed (owner decision; not done this session).
- Pi on this machine is now **1.3.0** (owner-updated mid-session). Run
  `pi update` before any Pi work.
- Local-only release posture unchanged: no RubyGems push, tag, or Git push;
  public publication tracked in #72. `run --max-runtime` caveats from 0.14.0
  still apply (owned process groups only; once-per-session notifications).

## Future

1. **If authorized:** cut 0.15.0 locally per the repo release procedure (skip
   RubyGems/tag/push), install, smoke `harnex doctor --adapter pi` and a short
   Pi bash receipt, write `koder/releases/0.15.0.md`.
2. Continue #56. #76 (`watch --stall-after`) is a P3 follow-up from #75 with
   open design questions listed in the issue.
3. Publish only when separately authorized (#72).
