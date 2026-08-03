# Harnex State

Updated: 2026-08-03 | 01:06 PM | IST

This is the thin session handoff. Durable history belongs in `CHANGELOG.md`,
release evidence in `koder/releases/`, and implementation detail in linked
issue/plan files.

## Past

- 2026-08-03 | 01:06 PM | IST: **#66 runner reliability hardening** — chasing
  what looked like a test flake found four production defects: concurrent
  registry writes corrupting each other (pid-only temp name; 2080 failures in a
  2400-write repro, now 0), a failed registry write failing an *already
  delivered* send, one corrupt registry pid crashing every session scan
  (`status`/`send`/`pane`), and a closed stdout killing the PTY reader so the
  wrapped agent blocked forever on write. Plus a test-isolation net so leaked
  threads/processes can't contaminate later tests. All five fixes are
  mutation-verified. Detail: `koder/issues/66_runner_reliability_hardening.md`.
- 2026-08-03 | 12:22 PM | IST: **#65 implemented and resolved** —
  `--summary-out` removed outright. `.harnex/dispatch.jsonl` is the only
  telemetry destination; both flag spellings hard-error with exit 2, and
  `TerminalStatus` no longer reads mirror files, so a leftover mirror from an
  older release cannot resolve stale status. `source` for rich end rows is now
  `dispatch_end`. Detail: `koder/issues/65_remove_summary_out_mirror.md`; full
  suite 647 runs, 0 failures/errors, 2 environment-gated skips.
- 2026-08-03 | 11:45 AM | IST: **Open/close skills refreshed to the current
  koder-pattern format** (`b84f5f1`). Tiny front doors now route to bounded
  workflows and compact output contracts while retaining Harnex-specific
  artifact-loading, timestamp, telemetry, and clean-close rules under
  `.claude/skills/{open,close}/` (also exposed through the Pi alias).
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

- #64, #65, and #66 are implemented, documented, and verified, and all three
  are unreleased. No active implementation blocker — the next step is cutting
  the release.
- The suite is clean across **40/40 consecutive randomized-order runs** (658
  runs, 2836 assertions, 2 environment-gated skips). If a future run fails,
  treat it as a real defect first: every "flake" investigated in #66 turned out
  to be a production bug.
- #65 is **breaking on purpose**: the next release must be a minor bump
  (0.10.0), and its notes must lead with the removed flag. Holm already
  assumes canonical-only as of 2026-08-03, so no Holm change is needed.
- The compatibility `--require-artifact-report` / `init` surfaces remain, while
  normal dispatches need no model-authored JSON or explicit receipt path.
- #58 remains open: interactive Claude usage is explicit `unsupported`; no
  cache-write mapping or price is guessed.
- Deliberately *not* fixed in #66, and still open: the cross-process
  lost-update race between a live session persisting its registry and the
  parent `harnex run` running `annotate_tmux_registry` on the same file. Each
  write is atomic and the merge is intentional, so this is a stale-field risk
  rather than corruption.

## Future

1. Cut `0.10.0` covering #64, #65, and #66, and write
   `koder/releases/0.10.0.md` before publishing/installing it.
2. Implement #56 adapter preflight, then converge #57/#59 into the deterministic
   queue runner required by Holm Plan 708.S04.
3. #45 Pi PTY stable markers, then #42 / Plan 30 recovery/fallback phases and
   #41 Slice C public API docs.
