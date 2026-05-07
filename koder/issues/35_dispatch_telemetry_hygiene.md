# #35 — DISPATCH.jsonl telemetry hygiene

**Status:** open
**Priority:** P2
**Filed:** 2026-05-07 (after 0.6.5 release verification)

## Why

`DISPATCH.jsonl` was built incrementally and never reviewed end-to-end.
Spot-check of `Session#build_summary_actual` and `#build_summary_meta`
(`lib/harnex/runtime/session.rb:822-894`) against what harnex actually
captures shows three classes of problem:

1. **Captured-but-dropped:** values harnex already tracks internally
   that never make it into the row.
2. **Always-null dead fields:** schema columns that no code path
   populates, making consumers think the data is missing rather than
   never wired up.
3. **Schema inconsistencies:** fields that appear conditionally or are
   hardcoded incorrectly, breaking downstream JSON Lines analysis.

Goal: make every column either reliably populated or explicitly
removed, with no "always null" fields and no captured signals dropped
on the floor.

## Tier 1 — bugfix-shaped (close obvious gaps)

These are not design debates. The data is already captured and
silently dropped, or the schema is internally inconsistent.

- **`total_tokens`** — listed in `USAGE_FIELDS` (`session.rb:9-11`)
  but never copied into `actual`. Add to `build_summary_actual`.
- **`agent_session_id`** — also listed in `USAGE_FIELDS`, also never
  written. This is the Codex `thread.id` UUID; invaluable for
  cross-referencing harnex telemetry with Codex's own logs.
- **`adapter_transport`** — `:pty` vs `:stdio_jsonrpc`. Lets
  consumers filter perf metrics by transport without re-parsing meta.
  Read from `adapter.transport`.
- **`task_complete`** (bool) — `@last_completed_at` is tracked but
  not exposed. Today `exit: "success"` couples to "tokens were
  captured" rather than "`task_complete` notification fired"
  (`session.rb:801-819`). Adding an explicit boolean decouples task
  outcome from telemetry availability and unblocks the §1 audit
  finding from `quality-audit` 2026-05-07.
- **`signal`** + **`exit_code`** — raw process exit info. STATE.md
  notes we preserve `signal` separately on signaled exits, but
  DISPATCH only has the synthesized `exit` reason.
- **`last_error`** — currently added only when
  `exit == "boot_failure"`. Other rows omit the key entirely. Make it
  always present, `null` when absent — JSON Lines consumers expect
  stable shape per row.
- **`tmux_session`** — hardcoded to `id` regardless of whether the
  session was tmux-backed (`session.rb:836`). Read the registry's
  actual `tmux_session` value, or set `null` for headless. (Already
  flagged in `quality-audit` §1, finding 9.)

## Tier 2 — small features (one event counter or registry read each)

- **`turn_count`** / **`message_count`** — `@injected_count` is in
  the live status payload but not DISPATCH.
- **`auto_disconnects`** — tracked separately from the lifetime
  `disconnections` count in the registry/status; DISPATCH currently
  only has the latter.
- **`output_log_path`** / **`events_log_path`** — let post-hoc
  analysis find the artefacts without recomputing the repo-key hash.
- **`parent_dispatch_id`** auto-derive — when the invoker has
  `$HARNEX_ID` set, that's the parent dispatch. Today it's only
  filled via explicit `--meta parent_dispatch_id=…`. Auto-derive when
  unset.
- **`tool_calls`** / **`commands_executed`** — countable from
  `item_completed` events (`mcpToolCall`, `dynamicToolCall`,
  `commandExecution`). Useful "how much real work did this worker
  do" signal.
- **`rate_limits`** — Codex sends `thread/rateLimits/updated`; we
  currently ignore it (`session.rb:419-421`). At minimum, store the
  last snapshot in the row.

## Tier 3 — decide: populate or remove always-null fields

- **`cost_usd`** — always `nil`. Either compute from `model` + a
  token-rate table, or drop the column.
- **`tests_run` / `tests_passed` / `tests_failed`** — always `nil`.
  No code path populates them. Drop, or wire from a heuristic
  (transcript scan).
- **`agent_version` / `agent_provider` / `agent_deployment`** —
  always `nil`. `agent_version` is a one-liner: shell out
  `<cli> --version` at adapter init and cache.
- **`approvals_handled`** — JSON-RPC approval mediator could expose
  an auto-approval count. Useful for sandbox/policy auditing once
  approvals matter.
- **`predicted: {}`** — empty for nearly every row in the wild. If
  `--meta predicted=…` is rare, this field bloats the schema. Either
  document it as the canonical pre-task forecast surface or move
  under a sparser key.

## Tier 4 — richer captures (only if cheap)

- **`commit_shas: [...]`** — list of SHAs in the `[start, end]`
  range, richer than `commits: N`. We already run `git diff` for the
  count.
- **`branch_end`** — branch can change mid-session (worker checks
  out a feature branch). Today only `branch` at start is captured.

## Recommended order

1. Land Tier 1 as a single commit. No design debate, all are obvious
   captured-but-dropped or schema-inconsistency fixes.
2. Land Tier 2 as a follow-up commit (or two — splitting derived
   fields from log-path fields keeps each commit reviewable).
3. Tier 3 is a separate decision: populate vs remove. Don't leave
   always-null fields.
4. Tier 4 only if we want it. Skip if not.

## Out of scope

- Schema versioning. If the row shape changes meaningfully, add a
  `schema_version` field once, then bump it on changes. Not in this
  issue.
- Holm-side `SESSION.jsonl` consumption. That's a holm bookkeeping
  artefact, populated by holm's own session scripts; harnex has no
  code path that writes there.

## Done when

- Every column in `actual` and `meta` is either populated by a known
  code path or explicitly removed.
- No conditional-presence fields — every row has the same keys.
- A new test asserts the row schema (key set + types) end-to-end so
  silent regressions don't sneak in.
