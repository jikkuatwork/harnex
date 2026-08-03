# Harnex State

Updated: 2026-08-03 | 02:04 PM | IST

This is the thin session handoff. Durable history belongs in `CHANGELOG.md`,
release evidence in `koder/releases/`, and implementation detail in linked
issue/plan files.

## Past

- 2026-08-03 | 02:00 PM | IST: **`harnex 0.10.0` shipped** (`de7cd12`, `v0.10.0`)
  covering #64, #65, and #66. Published to RubyGems and installed locally;
  `harnex --version` reports `0.10.0`. **Breaking:** `--summary-out` is gone.
  Verification: `koder/releases/0.10.0.md`.
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

- Nothing is in flight. `0.10.0` is released, installed, and smoke-tested; the
  working tree is clean and `main` is pushed.
- Consumers upgrading to `0.10.0` hit one breaking change: `--summary-out` now
  hard-errors. Holm already assumes canonical-only as of 2026-08-03, so no Holm
  change is needed; any other caller must drop the flag.
- Treat a failing test run as a real defect, not a flake. The suite is clean
  across 40/40 randomized-order runs, and every "flake" investigated in #66
  turned out to be a production bug.
- `0.10.0` shipped **without a real-agent smoke** (stub Ruby agents only) and
  without an independent reviewer pass — both of which 0.9.0 had. Worth a live
  Codex dispatch early next session to close that gap.
- #58 remains open: interactive Claude usage is explicit `unsupported`; no
  cache-write mapping or price is guessed.
- Known and unaddressed: the cross-process lost-update race between a live
  session persisting its registry and the parent `harnex run` running
  `annotate_tmux_registry` on the same file. Each write is atomic and the merge
  is intentional, so this is a stale-field risk rather than corruption.

## Future

1. Run a live Codex dispatch against installed `0.10.0` to close the
   real-agent verification gap noted in `koder/releases/0.10.0.md`.
2. Implement #56 adapter preflight, then converge #57/#59 into the deterministic
   queue runner required by Holm Plan 708.S04.
3. #45 Pi PTY stable markers, then #42 / Plan 30 recovery/fallback phases and
   #41 Slice C public API docs.
