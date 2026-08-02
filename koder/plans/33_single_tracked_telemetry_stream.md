---
status: planned
issue: 63
plan: 33
tier: B
layer: single-stream-telemetry
created: 2026-08-02
phases: 7
---

# Plan 33 — One versioned telemetry stream (#63)

## Goal

Collapse the thin/rich record split so every dispatch writes exactly two
rows — a `dispatch_start` row and one **rich** `dispatch_end` row — into one
repo-tracked `.harnex/dispatch.jsonl` resolved by one canonical path rule.
Along the way: price-table cost for adapters that report tokens but not cost
(subsumes #58's cost gap), harness-owned attempt linkage, opt-in `meta.phase`
allowlist validation, and retention caps for the unbounded
`~/.local/state/harnex/{events,output}` directories (5.4G + 668M observed
locally on 2026-08-02).

## Current state (verified 2026-08-02 at `591e59b`)

- Per dispatch with default flags, **three** rows land in
  `.harnex/dispatch.jsonl`: the `dispatch_start` row and thin `dispatch_end`
  row via `DispatchHistory` (`lib/harnex/runtime/session.rb:1999`, `:2005`),
  plus the rich summary row via `append_summary_record`
  (`session.rb:1986-1996`) because `--summary-out` defaults to the same file
  (`lib/harnex/core.rb:117-122`, `lib/harnex/commands/run.rb:845-850`).
  Consumers that redirect `--summary-out` (Holm → gitignored scratch) strand
  the rich rows outside version control.
- The rich row has **no top-level envelope** — no `schema_version`,
  `record_type`, or `id`. `TerminalStatus` duck-types it as
  `meta.is_a?(Hash) && actual.is_a?(Hash)`
  (`lib/harnex/terminal_status.rb:97-103`); `harnex history` skips it
  entirely (fix `591e59b`).
- Path resolution diverges: thin rows use `DispatchHistory.path_for` —
  git-root walk with global fallback (`lib/harnex/dispatch_history.rb:16-23`)
  — while the rich row uses `File.join(repo_root, ".harnex", ...)` with no
  git-root walk and no global fallback (`core.rb:117-122`).
- Attempt/reliability fields are hardcoded: `attempts_total: 1`,
  `fallback_triggered: false` (`session.rb:1842`, `:1852`),
  `reliability.recovered: false` (`session.rb:1795`).
- `usage.cost_usd` is null for Codex (tokens observed, no price) and Claude
  (no usage producer at all — #58). Only Pi reports cost.
- `meta.phase` is a free string; Holm accumulated 62 distinct values.
- `~/.local/state/harnex/{events,output}` grow without bound
  (`core.rb:240-248`).

## Locked decisions

1. **The v2 `dispatch_end` row is the rich row plus the thin row's
   envelope.** Top level keeps every field `harnex history` and
   `DispatchHistory` predicates read today: `schema_version`, `record_type`,
   `id`, `session_id`, `description`, `cli`, `started_at`, `ended_at`,
   `duration_s`, `status`, `terminal_event`, `commit_sha`, `tier`,
   `tmux_state`, `events_log_path`, `summary_out_path`. The rich sections
   (`meta`, `predicted`, `actual`, `agent`, `usage`, `context`,
   `attribution`, `outcome`, `attempt`, `reliability`, `queue?`,
   `orchestration?`, artifact-report keys) ride alongside unchanged — **no
   section redesign in this plan**.
2. **`meta` collision resolves to the rich side.** The thin row's `meta`
   (raw `meta_hash` passthrough) is dropped; the merged row carries
   `build_summary_meta` (`session.rb:1498-1529`), which is a superset
   (passthrough fields plus provenance). Top-level `tier` stays for the
   history renderer.
3. **`schema_version: 2` on both start and end rows** from the same release —
   one family stamp marking the unified era. Predicates key on `record_type`,
   not version; the legacy clause (`schema_version == 1 && status &&
   !record_type`) stays for old thin rows. Readers accept v1 and v2 mixed in
   one file (this repo's file already mixes eras).
4. **One path rule: `DispatchHistory.path_for`** (git-root walk from launch
   cwd, global fallback) for every writer and reader.
   `Harnex.default_summary_out_path` is deleted.
5. **`--summary-out` becomes an explicit-only mirror.** No default. When
   set, the identical v2 end record is appended there too. Flag documented
   as a compatibility mirror; removal is out of scope. The `summary` event
   (`session.rb:1250`) points at the tracked stream path, with
   `mirror_path` when a mirror is configured.
6. **Cost is computed, never guessed.** New `lib/harnex/pricing.rb`: static
   per-1M-token USD rates keyed by provider + model, each entry carrying an
   `as_of` date, sourced from provider pricing pages at implementation time.
   Applied in `build_summary_usage` (`session.rb:1558-1594`) only when
   `cost_usd` is nil, usage status is `observed`/`zero`, and the effective
   model matches the table → `cost_source: "price_table"` and
   `cost_price_as_of` set. Unknown model or missing component rates →
   `cost_usd` stays null. Implementation must verify Codex token semantics
   (whether `output_tokens` already includes `reasoning_tokens`) against the
   captured schema fixtures before choosing the formula.
7. **Attempt linkage is harness-derived from the stream.** At finalize,
   walk the tracked stream's `parent_dispatch_id` links (sanctioned by #62's
   retry path) to the chain root: `attempts_total` = chain length,
   `attempts_succeeded`/`attempts_failed` = observed end-row statuses plus
   this attempt, `fallback_triggered` = any chain member (incl. self) with
   `attempt.kind == "fallback"`, `reliability.recovered` = this attempt
   succeeded and its parent's end row failed. Caller-supplied `--meta`
   values no longer feed these fields.
8. **Phase validation is opt-in repo config.** `.harnex/config.json`:
   `{"phase": {"allowlist": [...], "policy": "warn" | "reject"}}`, checked
   at `harnex run` argument validation. No config → no validation. `warn`
   prints to stderr and dispatches; `reject` exits non-zero before spawn.
9. **Retention is opportunistic prune with conservative defaults.** Caps
   per directory (`events`, `output`): max age 45 days AND max total size
   1 GiB, configurable via the same config file and
   `HARNEX_EVENTS_MAX_*`/`HARNEX_OUTPUT_MAX_*` env. Enforced oldest-first at
   dispatch registration; files belonging to live sessions (registry pid
   alive, or uncompleted start row with alive pid) and the current session
   are never deleted. `harnex doctor` reports directory sizes and last
   prune; `harnex doctor --prune` runs it manually.
10. **`koder/DISPATCH.jsonl` is untouched** — it is repo-level telemetry
    appended by sessions, not part of this stream.

## Phase 1 — Unified v2 end row, single stream, canonical path

Goals 1 + 2 of the issue. The keystone phase; everything else layers on it.

- `DispatchHistory.build_record(session)` gains the envelope-merge: thin
  top-level fields (minus `meta`) merged with the sections from
  `Session#build_summary_record`, stamped `schema_version: 2`. Start rows
  stamp 2 as well (`build_start_record`).
- `finalize_session!` (`session.rb:1273-1293`) writes the merged row once
  via `append_dispatch_history_record`; `append_summary_record` runs only
  when an explicit `--summary-out` mirror is configured and writes the same
  record.
- Delete `Harnex.default_summary_out_path`; `resolve_summary_out`
  (`run.rb:845-850`) returns nil when unset. Audit `run.rb:206`/`:275`
  (tmux passthrough) for nil-safety.
- `TerminalStatus`: resolve a v2 end row as both summary and history record
  in one shot (`scan_dispatch_path`, `terminal_status.rb:74-103`); keep the
  legacy duck-types for pre-v2 files.
- `harnex history` renders v2 rows through the existing top-level fields —
  verify no renderer change is needed; the `591e59b` skip logic must keep
  skipping legacy envelope-less rich rows.
- Tests: `test/dispatch_row_schema_test.rb` (notably
  `test_dispatch_stream_writes_paired_start_and_end_rows`, `:485`) asserts
  exactly one start + one end row per dispatch and the v2 envelope + section
  keys; `dispatch_history_test.rb` predicate/pairing coverage for v2;
  TerminalStatus resolution from a unified stream; mirror-only
  `--summary-out` behavior; mixed v1+v2 file reads.

Exit: a default dispatch writes exactly two rows to the canonical tracked
path; `wait --until done`, `status`, `history`, and `TerminalStatus` all
resolve from them; suite green.

## Phase 2 — Price-table cost for token-reporting adapters

Goal 3, Codex half — satisfies the issue's cost acceptance criterion.

- Add `lib/harnex/pricing.rb` per locked decision 6; wire into
  `build_summary_usage`.
- Source current Codex (OpenAI) and Claude (Anthropic) model rates with
  `as_of` dates; document the update procedure in the file header.
- Tests: fixture-driven — observed Codex tokens + known model → non-null
  `cost_usd`, `cost_source: "price_table"`; unknown model → null cost,
  source absent; provider-reported cost (Pi) never overwritten.

Exit: a Codex dispatch records non-null `cost_usd` with `cost_source` set.

## Phase 3 — Claude usage producer (first slice of subsumed #58)

Goal 3, Claude half. Separable: phases 4-7 do not depend on it, and the
issue's acceptance criteria gate only Codex — if the Claude CLI surface
fights back, ship the release without this phase and leave #58 open for the
remainder.

- Implement #58's first useful slice: headless `claude -p --output-format
  stream-json` usage/model capture for `--auto-stop` dispatches, everything
  else explicitly `usage.status: "unsupported"`. Bounded fields only —
  never message content.
- Phase 2's table then prices Claude tokens the same way.
- Tests: fixture stream-json payloads → usage + cost; PTY interactive path
  still reports `unsupported`.

Exit: an auto-stop Claude dispatch records usage tokens and priced cost, or
the phase is explicitly deferred in the release notes with #58 kept open.

## Phase 4 — Harness-owned attempt linkage

Goal 4, per locked decision 7.

- Replace hardcoded `attempts_total`/`attempts_succeeded`/`attempts_failed`/
  `fallback_triggered` (`session.rb:1842-1852`) and
  `reliability.recovered` (`:1795`) with chain-walk derivation over the
  tracked stream. Bounded: one `File.foreach` pass building an id-indexed
  chain, following `parent_dispatch_id` links.
- `retry_count` from event counters stays as-is (different signal: in-run
  retries vs. cross-dispatch attempts).
- Tests: initial → retry → retry chain via #62's sanctioned path yields
  `attempts_total: 3` on the last row; fallback kind sets
  `fallback_triggered`; success-after-failure sets `recovered`; missing
  parent rows degrade to self-only counts, never raise.

Exit: the issue's retry acceptance criterion — a #62-sanctioned retry
increments harness-owned counters.

## Phase 5 — `meta.phase` allowlist validation

Goal 5, per locked decision 8.

- Minimal config loader for `.harnex/config.json` (repo-root of launch cwd,
  same path rule as the stream). Validate `meta.phase` at `harnex run`
  argument validation, before spawn.
- Tests: no config → any phase passes; `warn` policy → stderr warning,
  dispatch proceeds; `reject` → non-zero exit, no dispatch row written;
  allowlisted phase passes silently.

Exit: a consumer can enforce a canonical phase set without patching harnex.

## Phase 6 — Events/output retention

Goal 6, per locked decision 9.

- Prune hook at dispatch registration + `harnex doctor --prune`; doctor
  reports directory sizes either way.
- Tests: over-cap synthetic directories prune oldest-first to under caps;
  live-session files and the current session's logs survive; env/config
  overrides respected.

Exit: `{events,output}` respect configured size/age caps — the issue's
retention acceptance criterion.

## Phase 7 — Docs, migration note, verification

Goal 7 plus release hygiene.

- Update `guides/` (dispatch/monitoring topics) for: two rows per dispatch,
  v2 envelope, `--summary-out` mirror semantics, phase allowlist, retention
  knobs, cost provenance values.
- Migration note (CHANGELOG + release record): consumers stop redirecting
  `--summary-out`; scratch-history import guidance for Holm (rich scratch
  rows ≈ v2 sections without envelope; Holm's one-time import of its 1,156
  scratch records is Holm-side work).
- Full suite + installed-binary smoke of `run`/`wait`/`status`/`history`
  against a real dispatch; release per CLAUDE.md checklist (minor bump —
  row-shape change is consumer-visible).

## Risks and guards

- **Readers in the wild:** `wait --until done`'s exit-code contract and
  `status --id` fall back to stream rows (`latest_rows`,
  `live_start_record`). Both key on `record_type`, which v2 preserves;
  Phase 1's schema tests must cover both paths against v2 rows.
- **Mixed-era files:** every reader change is additive — v1 thin rows and
  envelope-less legacy rich rows must keep resolving (regression tests over
  a fixture file containing all three eras).
- **Duck-type collision:** a v2 row matches the legacy `summary_record?`
  shape (`meta` + `actual`). `TerminalStatus` must branch on
  `record_type` first so a v2 row is never double-counted as a separate
  summary/history pair.
- **Price staleness:** `as_of`-dated entries, null-on-unknown, and a
  documented update procedure; never backfill costs for rows written before
  the table existed.
- **Retention safety:** deletion is capped-scope (the two harnex-owned state
  dirs), oldest-first, live-session-excluded, and default-conservative. A
  dry-run mode in `doctor --prune` output lists what would go.
- **Holm coordination:** land Phase 1 and the migration note in the same
  release so Holm's queue tooling flips `--summary-out` off exactly once.
