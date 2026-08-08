# Harnex State

Updated: 2026-08-08 | 06:55 PM | IST

This is the thin session handoff. Durable history belongs in `CHANGELOG.md`,
release evidence in `koder/releases/`, and implementation detail in linked
issue/plan files.

## Past

- 2026-08-08 | 06:52 PM | IST: **`harnex 0.10.2` shipped** (`ef25148`,
  `v0.10.2`), a docs-only patch from holm Analysis 803: the packaged
  monitoring guide's Completion Test now excludes the harness-owned
  `.harnex/dispatch.jsonl` from clean-tree checks, and anti-patterns cover
  from-memory "no live sessions" claims (finished agents park at prompts)
  and fences tripping on dispatch-stream growth.
  `docs/dispatch-telemetry.md` documents the tracked stream as
  harness-owned. Full suite green (671 runs), published to RubyGems,
  installed locally, installed `agents-guide monitoring` verified serving
  the new text. Verification: `koder/releases/0.10.2.md`.
- 2026-08-04 | 12:29 AM | IST: **`harnex 0.10.1` shipped** (`a12e00c`,
  `v0.10.1`) for Issue #67 / Plan 34. `telemetry assert-canonical` provides a
  read-only mixed-era/source drift gate; `telemetry reconcile` is dry-run-first
  and appends only reviewed missing rich end rows with `--apply`. Published to
  RubyGems, installed locally, and verified against actual Holm legacy rows,
  the 3563-row Holm corpus, and a real Codex dispatch. Verification:
  `koder/releases/0.10.1.md`.
- 2026-08-03 | 02:00 PM | IST: **`harnex 0.10.0` shipped** (`de7cd12`,
  `v0.10.0`) covering #64, #65, and #66: harness-authored receipts, removal of
  `--summary-out`, and runner reliability hardening. Verification:
  `koder/releases/0.10.0.md`.
- 2026-08-03 | 01:16 AM | IST: **`harnex 0.9.0` shipped** for #63 / Plan 33,
  establishing the single tracked rich v2 telemetry stream.

## Present

- Nothing is in flight. `0.10.2` (docs-only) is published, installed, and
  verified; `0.10.1` closed Issue #67 / Plan 34.
- Holm Plan `722` consumes the new invariant at close: scratch validation runs
  first, then canonical telemetry assertion, then session-ledger mutation.
  The close path never reconciles or deletes automatically.
- The working tree is expected clean and `main` pushed after this handoff.
- #58 remains open: interactive Claude usage is explicit `unsupported`; no
  cache-write mapping or price is guessed.
- Known and unaddressed: the cross-process lost-update race between a live
  session persisting its registry and parent `annotate_tmux_registry`. Writes
  are atomic; risk is stale fields rather than corruption.

## Future

1. Implement #56 adapter preflight, then converge #57/#59 into the deterministic
   conveyor runner required by Holm Plan 708.S04.
2. #45 Pi PTY stable markers, then #42 / Plan 30 recovery/fallback phases.
3. #41 Slice C public API docs and #58 Claude usage when a bounded producer is
   available.
