# Harnex State

Updated: 2026-10-16 | 07:30 AM | +04

Thin session handoff. History: `CHANGELOG.md`; release evidence:
`koder/releases/`; implementation detail: linked issues/plans.

## Past

- **0.15.0 is installed locally and verified on PATH** from `81c6cb8`.
  #70: Pi receipts attest bash command text + integer exits; missing evidence
  fails closed (`command_observation: partial|unsupported`,
  `observed.commands_unobserved`); doctor advertises `pi_command_proof: 1`.
  #75: `wait`/`watch` survive a sibling registry vanishing mid-scan.
  Full suite: 834 runs / 3,914 assertions / no failures or errors / three
  opt-in skips; installed-gem regressions and a live installed-CLI Pi smoke
  pass. Exact package and non-coverage: `koder/releases/0.15.0.md`.
- 0.14.1 (#74) and earlier gems remain installed as rollback.

## Present

- **Local-only release.** No RubyGems push, tag, or Git push; public
  publication tracked in #72. The exact 0.15.0 gem is in private validation
  storage (identity in the release record); do not rebuild 0.15.0 for
  publication without re-verification.
- Pi on this machine is **1.3.0**. Run `pi update` before any Pi work.
- `run --max-runtime` caveats from 0.14.0 still apply (owned process groups
  only; once-per-session notifications).

## Future

1. Holm can adopt Pi command proof after checking
   `capabilities.pi_command_proof == 1`; keep supervisor replay for high-risk
   acceptance (#70 non-goal).
2. Continue #56. #76 (`watch --stall-after`) is a P3 follow-up with open
   design questions in the issue.
3. Publish only when separately authorized (#72).
