---
status: open
priority: P1
issue_kind: slice
created: 2026-08-03
updated: 2026-08-03
tags: telemetry, dispatch-jsonl, summary-out, breaking, cleanup
---

# Issue 65 — Remove `--summary-out`; the canonical stream is the only destination

## Problem

`--summary-out` was demoted in 0.9.0 (#63) from a defaulted path to an
explicit-only "compatibility mirror", but it was not removed. The flag still
exists, and every consumer that still passes it appends a **byte-exact
duplicate** of the canonical end record into a second file — in practice a
gitignored scratch path nothing reads.

This is now a three-time-observed defect class, hand-reconciled each time:

| When | Consumer | Stranded rows | Reconciliation |
| --- | --- | --- | --- |
| 2026-08-02 | Holm | 1,156 | harnex #63 forensics |
| 2026-08-03 | Holm | 213 | Holm Analysis `719` (manual import) |
| 2026-08-03 | Holm | — | Holm Analysis `720` traced it to this flag |

Holm stopped passing `--summary-out-template` on 2026-08-03 (its
`scripts/harnex/dispatch-batch.sh` now hard-errors on the flag), so Holm has
stopped bleeding. The hole stays open for every other consumer and for any
future Holm caller that reintroduces it.

Demoting a footgun documents it; it does not retire it. The canonical stream
is self-sufficient post-0.9.0 (`session_id`-per-process + `@session_finalized`
guard + `flock`), so the mirror carries zero information the tracked stream
lacks.

## Goal

Delete the flag and its plumbing. `.harnex/dispatch.jsonl` becomes the only
destination a dispatch can write telemetry to. Passing the removed flag is a
hard error, not a silent ignore — a stale caller must fail loudly rather than
believe it has a second copy.

## Scope

Writer and flag plumbing:

- `lib/harnex/runtime/session.rb:2259-2271` — `append_summary_record` and its
  call site; delete.
- `lib/harnex/commands/run.rb` — usage lines `34`, `45`, `70`; option default
  `173`; `resolve_summary_out` call `208` and definition `875-881`; tmux
  re-exec passthrough `277`; session construction `443`; arg parsing
  `632-636`; the `--flag=value` regex sets at `728` and `748`.
- `lib/harnex/dispatch_history.rb:159,187` — stop emitting `summary_out_path`
  into records.

Internal consumer — this is the part that is **not** pure deletion:

- `lib/harnex/terminal_status.rb:25-31` prefers the mirror file when the
  history record carries `summary_out_path`, and reports
  `"source" => "summary_out"` (`:165-168`). Removing the writer without
  removing this branch leaves a resolver that reads a file nothing writes and
  that consumers may still have on disk from older runs — i.e. status can be
  resolved from stale mirror data. Canonical-stream resolution must become the
  only path; drop the `summary_out` / `summary_out_path` keys from the status
  payload (`:55`, `:165-168`, `:211`) and from `commands/status.rb:130,153`.

Docs:

- `docs/dispatch-telemetry.md:18,28,62` — remove the mirror section and the
  "omitting `--summary-out` is the normal path" phrasing (there is no longer a
  choice).
- `docs/events.md:117` — the event field describing the configured summary path.

## Acceptance Criteria

- `harnex run <agent> --summary-out PATH` exits non-zero with an unknown-option
  error; `--summary-out=PATH` likewise.
- No file other than `.harnex/dispatch.jsonl` receives a dispatch record.
- `harnex status --json` no longer carries `summary_out`; `source` never
  resolves to `"summary_out"`.
- A pre-existing mirror file on disk does not influence
  `TerminalStatus.resolve` for any id.
- Schema/telemetry tests updated; a regression test asserts the flag is
  rejected.
- Grep is clean: no `summary_out` / `summary-out` identifiers remain in `lib/`
  or `docs/` (the bench-script sense of the name in *consumer* repos is
  unrelated and out of scope).

## Notes

- **Breaking**, deliberately. Pre-1.0, and the flag's only remaining users are
  writing duplicates into scratch. A hard error surfaces them immediately;
  silent ignore would let a consumer keep believing in a second copy.
- Complements #63 goal 1 ("retire … the separate `--summary-out` default"),
  which demoted the default but left the flag. This closes it.
- Downstream: Holm's `scripts/harnex/dispatch-batch.sh` and
  `scripts/harnex/README.md` already assume canonical-only as of 2026-08-03;
  no Holm change is needed when this ships.
- Related: Holm `koder/analysis/720_spring_cleaning_meta_analysis/INDEX.md`
  (root-cause trace), Holm `koder/analysis/719_scratch_lifecycle_pass/INDEX.md`
  (the 213-row import).
