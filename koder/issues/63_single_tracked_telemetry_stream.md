---
status: resolved
priority: P2
issue_kind: slice
created: 2026-08-02
updated: 2026-08-03
resolved: Shipped in harnex 0.9.0; Claude usage producer remains in #58
plan: 33
tags: telemetry, dispatch-jsonl, schema, cost, retention, phases
---

# Issue 63 — One versioned telemetry stream; rich rows must be the durable ones

## Problem

Two record shapes share `.harnex/dispatch.jsonl` and only the thin one is
version-stamped. Consumers that redirect `--summary-out` (Holm routes it to
gitignored `koder/scratch/dispatch-telemetry.jsonl`) end up preserving the
analytically useless teardown rows while the rich rows (tokens, usage status,
reliability, outcome class, validation) live in scratch. Holm's 2026-08-02
process forensics (Holm `koder/plans/708_S00_process_mechanization_mapping/`)
had to mine the gitignored file for every substantive number.

Known gaps in the rich row itself:

- No `schema_version` (thin history row has one); discrimination is
  duck-typed (`lib/harnex/terminal_status.rb:96-102`).
- Writers resolve different paths: rich uses `repo_root`
  (`lib/harnex/core.rb:117-122`), thin uses launch-cwd git-toplevel
  (`lib/harnex/dispatch_history.rb:16-23`).
- `usage.cost_usd` is null for Codex and Claude (#58); only Pi reports cost.
- Attempt/retry linkage is caller-supplied and partly hardcoded:
  `attempts_total: 1`, `fallback_triggered: false`, `recovered: false`
  (`lib/harnex/runtime/session.rb:1840`, `:1850`, `:1793`).
- `meta.phase` is a free string — Holm accumulated 62 distinct phase names,
  which defeats aggregation.
- `~/.local/state/harnex/{events,output}` are unbounded (6GB+ observed), no
  rotation or retention policy.

## Goal

1. One record family in one repo-tracked `.harnex/dispatch.jsonl`:
   `schema_version`-stamped start row (#62) + rich end row; retire the
   thin/rich split and the separate `--summary-out` default.
2. One canonical path resolution shared by every writer and reader.
3. Populate `usage.cost_usd` (+`cost_source`) for Codex and Claude from token
   usage and a maintained price table when the provider doesn't report cost
   (subsumes #58).
4. Harness-owned attempt linkage: start/retry/fallback counted by harnex,
   not caller flags.
5. Optional `--meta.phase` enum validation (configurable allowlist; warn or
   reject per flag) so consumers can enforce a small canonical phase set.
6. Rotation/caps for events and output logs.
7. Migration note for consumers: Holm will stop routing `--summary-out` to
   scratch and one-time import its existing 1,156-record scratch history.

## Acceptance Criteria

- A dispatch produces exactly one start and one end record in the tracked
  stream; schema test updated; `TerminalStatus` resolves from the unified
  stream.
- Codex dispatch records a non-null `cost_usd` with `cost_source` set.
- Retry via #62's sanctioned path increments harness-owned attempt counters.
- Events/output directories respect a configurable size/age cap.

## Resolution

Shipped in `harnex 0.9.0`: one rich v2 start/end stream, exact-model/tier/context
Codex list-price cost, harness-derived attempt chains, phase policy, retention,
and packaged migration docs. Holm migrated off the scratch mirror and imported
its 1,156 legacy rich rows. Claude structured usage/cache-write mapping was
explicitly deferred and remains owned by open issue #58.
