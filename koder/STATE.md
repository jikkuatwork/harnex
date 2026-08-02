# Harnex State

Updated: 2026-08-03 | 01:18 AM | IST

This is the thin session handoff. Durable history belongs in `CHANGELOG.md`,
release evidence in `koder/releases/`, and implementation detail in linked
issue/plan files.

## Past

- 2026-08-03 | 01:16 AM | IST: **`harnex 0.9.0` shipped** (RubyGems,
  annotated `v0.9.0`, main/tag pushed, installed locally and version-verified):
  #63 / Plan 33 unified v2 tracked telemetry, exact guarded Codex list-price
  cost, harness-owned attempt linkage, phase allowlist, bounded log retention,
  and refreshed packaged docs. Verification: `koder/releases/0.9.0.md` plus
  bounded source/installed smoke JSON in `koder/releases/`.
- 2026-08-02 | 08:52 PM | IST: `harnex 0.8.0` shipped #62 live-run
  observability and duplicate-dispatch protection.

## Present

- No active release blocker. Full suite at the 0.9.0 release commit: 638 runs,
  0 failures, 2 environment-gated skips. Local `harnex --version` is 0.9.0;
  installed real Codex, mirror, history/status/wait, doctor, and packaged-doc
  smokes passed.
- #63 is resolved. Claude structured usage/cache-write mapping was deliberately
  excluded from 0.9.0 and remains open as #58; interactive Claude usage stays
  explicit `unsupported` rather than guessed.
- Retention defaults are 45 days and 1 GiB each for events/output. Verification
  used disposable state only; the next real dispatch may opportunistically
  prune expired/over-cap non-live logs.
- #64 (observed-state receipts), #57/#59 (outcome budgets + deterministic
  conveyor), #42/#43, and #45 remain open.

## Future

1. **Next: #64 observed-state receipts** — harness-authored proof replacing
   model-authored receipt ambiguity.
2. Implement #56 adapter preflight, then converge #57/#59 into the deterministic
   queue runner required by Holm Plan 708.S04.
3. Return to #58 only for explicitly authorized Claude dispatch telemetry; its
   cache-write mapping must be decided before pricing.
4. #45 Pi PTY stable markers, then #42 / Plan 30 recovery/fallback phases and
   #41 Slice C public API docs.
