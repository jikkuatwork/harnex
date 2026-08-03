# Harnex State

Updated: 2026-08-03 | 11:18 AM | IST

This is the thin session handoff. Durable history belongs in `CHANGELOG.md`,
release evidence in `koder/releases/`, and implementation detail in linked
issue/plan files.

## Past

- 2026-08-03 | 11:08 AM | IST: **#64 observed-state receipts implemented and
  resolved**. Harnex now generates proof from Git/command/turn/
  usage observations, keeps review claims advisory, validates final receipts,
  and retains them with other bounded runtime data. Detail:
  `koder/issues/64_observed_state_receipts.md`; full suite: 648 runs, 0
  failures/errors, 2 environment-gated skips; disposable CLI receipt smoke
  passed `artifact-report validate --final`.
- 2026-08-03 | 01:16 AM | IST: **`harnex 0.9.0` shipped** for #63 / Plan 33.
  Verification: `koder/releases/0.9.0.md`.

## Present

- #64 is implemented, documented, verified, and ready for the next release.
  It remains unreleased; no active implementation blocker.
- The compatibility `--require-artifact-report` / `init` surfaces remain, while
  normal dispatches need no model-authored JSON or explicit receipt path.
- #58 remains open: interactive Claude usage is explicit `unsupported`; no
  cache-write mapping or price is guessed.

## Future

1. Choose the next release version for #64 and produce the normal release
   verification record before publishing/installing it.
2. Implement #56 adapter preflight, then converge #57/#59 into the deterministic
   queue runner required by Holm Plan 708.S04.
3. #45 Pi PTY stable markers, then #42 / Plan 30 recovery/fallback phases and
   #41 Slice C public API docs.
