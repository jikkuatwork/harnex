# Plan 27: Dispatch telemetry capture (Layer 5 of issue #23)
Issue: #23
Date: 2026-05-01
Depends on: plan 26 (events bus shipped in v0.4.0)

## Goal
On every dispatch, capture a complete predicted-vs-actual telemetry record:
token counts (input/output/reasoning/cached) and `agent_session_id` parsed
from the codex session-end marker, wall-clock duration, git LOC/files/commits
between start and end SHAs, and operational counters (force_resumes,
disconnections). Surface the data through two channels — additive event types
on the v1 JSONL events stream (`usage`, `git`, `summary`) and a consolidated
one-line-per-dispatch record matching `holm/koder/DISPATCH.schema.md` written
to a project-local summary file. Predicted ranges enter via raw `--meta` JSON
only; harnex performs no name resolution and ships no pricing table — `cost_usd`
stays explicitly `null` for downstream computation.

## Scope guardrails
In scope:
- new `--meta` and `--summary-out` flags on `harnex run`
- adapter contract for session-end summary parsing (codex-first)
- session-level capture of `start_sha`/`end_sha` and `git diff --shortstat`
- additive event types `usage`, `git`, `summary`
- consolidated record writer matching the holm DISPATCH schema
- failure-mode handling (no summary block ⇒ partial record with null tokens)
- docs additions

Out of scope (restated, see "Out of scope" below):
- pricing/cost computation, calibration analysis, multi-agent telemetry
  fields, retroactive ingestion, dispatch refusal on cost ceilings.

## Design decisions

### Q1. Capture mechanism
Codex emits a deterministic plain-text marker on session end. Verified by
sampling the live transcript at `~/.local/state/harnex/output/<repo>--<id>.log`
(after ANSI stripping):

```
Token usage: total=106,867 input=104,158 (+ 250,880 cached) output=2,709 (reasoning 870)
To continue this session, run codex resume 019ddf05-0f03-7d70-904f-23db7f00640f
```

There is no first-class JSON output mode. Probing a JSON-rpc surface adds
risk and depends on codex internals. The marker above is stable enough to
match with two regexes:

- Tokens: `/Token usage:\s+total=([\d,]+)\s+input=([\d,]+)(?:\s+\(\+\s+([\d,]+)\s+cached\))?\s+output=([\d,]+)(?:\s+\(reasoning\s+([\d,]+)\))?/`
- Resume UUID: `/codex resume\s+([0-9a-f-]{36})/`

The adapter exposes a `parse_session_summary(transcript_tail)` method
returning `{input_tokens:, output_tokens:, reasoning_tokens:, cached_tokens:,
total_tokens:, agent_session_id:}` with `nil` for any field it could not
extract. The session reads the last 16 KB of the output log after process
exit, runs `Harnex.strip_ansi(...)`, and hands it to the adapter.

**Decision:** Parse the stripped transcript tail with regex inside the
adapter, called by the session at process exit. No JSON-rpc, no codex
internals.

### Q2. Output channel
Both. The events stream is the high-fidelity raw record (one event per
extracted concern); the consolidated summary file is the downstream-friendly
single-line-per-dispatch shape that holm and other consumers already expect.
Emitting both keeps the events bus coherent (every measurement has a typed
event) and lets consumers ignore one channel if they prefer the other. The
summary file is written *after* the events are emitted so a `summary` event
can include the `path`.

**Decision:** Emit `usage`, `git`, `summary` events into the JSONL events
stream **and** append one consolidated JSON line to a summary file. Default
summary path: `<repo_root>/koder/DISPATCH.jsonl` if a `koder/` directory
exists in the repo root; otherwise the writer is silent unless
`--summary-out PATH` was passed.

### Q3. Predicted-data input
The orchestrator passes raw JSON via `--meta`. Harnex parses the JSON,
echoes the entire object onto the `started` event under a `meta` field, and
later splits it into the `meta` (identity/context) and `predicted` (model,
effort, ranges) blocks of the consolidated record using a fixed convention:
- top-level keys whose name matches a known meta field flow into `meta`
- a top-level `predicted` object flows verbatim into `predicted`
- unknown keys are preserved on the `started` event but not surfaced into
  the consolidated record (forward-compatible)

No name resolution, no lookup files, no built-in dispatch buckets. Harnex
remains unaware of the consumer's `recommendations.md` table.

**Decision:** `--meta '<json>'` is the single intake. JSON parse errors
fail `harnex run` with a clear error. Empty/missing `--meta` is fine —
predicted block is `{}` and meta fields harnex itself owns
(`id`, `started_at`, `ended_at`, `harness`, `harness_version`, `agent`,
`host`, `platform`, `repo`, `branch`, `start_sha`, `end_sha`) are populated
unconditionally.

### Q4. LOC capture
Add minimal git awareness inside harnex with graceful no-op when the dispatch
target is not a git repo:

- At session start (after `started` event): shell out to
  `git -C <repo_root> rev-parse HEAD` and `git rev-parse --abbrev-ref HEAD`.
  Record `start_sha` and `branch` on a `git` event with `phase:"start"`.
- At session end (after process exit, before `exited` event): shell out to
  `git -C <repo_root> rev-parse HEAD`,
  `git -C <repo_root> diff --shortstat <start_sha>..<end_sha>`, and
  `git -C <repo_root> rev-list --count <start_sha>..<end_sha>`.
  Record `end_sha`, `loc_added`, `loc_removed`, `files_changed`, `commits`
  on a `git` event with `phase:"end"`.

Failures (not a repo, command not found, dirty index between SHAs) leave
those fields `null` on the consolidated record. No retry, no fallback.

**Decision:** harnex captures git itself at start + end of session, with
explicit null on any git failure. Keeps the consolidated record self-
contained; one fewer post-session shim for consumers.

### Q5. Cost calculation
`actual.cost_usd` is **always** written as `null` by harnex in v1. Token
counts are recorded raw; consumers compute cost downstream against their
own pricing tables. Reasoning: harnex would otherwise have to ship and
maintain a per-model price table that drifts with vendor pricing changes.
Pushing pricing to the consumer matches the same line that keeps harnex out
of name-resolution (Q3).

**Decision:** `actual.cost_usd: null` always; no pricing table inside
harnex. Document the contract in `docs/dispatch-telemetry.md`.

### Q6. Multi-adapter generalization
Adapter-agnostic: the new event types are not codex-specific. The adapter
base class declares `parse_session_summary(transcript_tail) ⇒ {}`; codex
overrides it. The session unconditionally calls the adapter at exit and
emits a `usage` event populated from whatever the adapter returned. A
non-overriding adapter (claude, generic) yields a `usage` event whose
extractable fields are all `null` — no special-casing in the session, the
event is still emitted for schema uniformity.

**Decision:** Event shape is shared; adapter provides extraction. Codex
ships parsing in this plan; claude/generic stay null until a follow-up.

### Q7. Failure modes
Three failure surfaces and their policies:

1. **No summary block in transcript.** Adapter returns hash with all token
   fields `nil`. Session still emits a `usage` event with `null` fields and
   still writes the consolidated record with `actual.input_tokens: null`
   etc. `actual.exit` is set to `"failure"` if exit code ≠ 0, otherwise
   `"disconnected"` (codex did not produce a summary ⇒ session did not
   shut down cleanly).
2. **Force-resume during `--watch`.** `usage` events (and the consolidated
   record) are emitted **once per dispatch**, at process exit, never on
   intermediate resumes — codex's session-end marker only appears at real
   exit. The session counts `resume` events on the events bus (Layer 2's
   producer) between `started` and `exited`; that count becomes
   `actual.force_resumes`.
3. **Codex disconnects mid-session and PTY closes uncleanly.** Same as
   case 1 — adapter returns nulls, `actual.exit = "disconnected"`,
   `actual.disconnections = 1`. The consolidated record is still written.

The summary file write itself is best-effort: any `IOError` is logged via
`warn(...)` (matching the existing `@output_log_failed`/`@events_log_failed`
pattern) and does not block exit. Idempotency: the writer always appends
exactly one line per dispatch lifecycle, keyed on `meta.id` + `meta.started_at`;
duplicate-write protection is not required because each `Session` instance
runs the writer at most once on its own exit path.

**Decision:** Always write the consolidated record at exit, even with all-
null actuals. Use `actual.exit` to communicate which failure mode applied.
Counters (`stalls`, `force_resumes`, `disconnections`, `compactions`) are
derived by tallying typed events on the bus between `started` and `exited`.
`tests_run/passed/failed` always `null` in v1 (out of scope to detect).

## Schema additions

All additions are additive to schema_version `1`. Existing fields untouched.

### New event type: `usage`
Emitted once per session, after process exit and before `exited`.
```json
{
  "schema_version": 1,
  "seq": 17,
  "ts": "2026-05-01T11:42:13Z",
  "id": "cx-i-372",
  "type": "usage",
  "input_tokens": 104158,
  "output_tokens": 2709,
  "reasoning_tokens": 870,
  "cached_tokens": 250880,
  "total_tokens": 106867,
  "agent_session_id": "019ddf05-0f03-7d70-904f-23db7f00640f"
}
```
All fields except envelope are nullable.

### New event type: `git`
Emitted at most twice per session. `phase:"start"` after `started`,
`phase:"end"` after process exit and before `exited`. Omitted entirely if
git is unavailable (no event rather than a null event — keeps git-less
runs uncluttered).
```json
{
  "schema_version": 1,
  "seq": 2,
  "ts": "2026-05-01T11:30:00Z",
  "id": "cx-i-372",
  "type": "git",
  "phase": "start",
  "sha": "a8114695c1f0",
  "branch": "master"
}
```
```json
{
  "schema_version": 1,
  "seq": 18,
  "ts": "2026-05-01T11:42:13Z",
  "id": "cx-i-372",
  "type": "git",
  "phase": "end",
  "sha": "abc1234567",
  "loc_added": 312,
  "loc_removed": 65,
  "files_changed": 7,
  "commits": 1
}
```

### New event type: `summary`
Emitted last, immediately before `exited`. One line per session.
```json
{
  "schema_version": 1,
  "seq": 19,
  "ts": "2026-05-01T11:42:13Z",
  "id": "cx-i-372",
  "type": "summary",
  "path": "/home/u/proj/koder/DISPATCH.jsonl",
  "exit": "success"
}
```

### New optional fields on existing events
- `started`: optional `meta` (Object) — verbatim parsed `--meta` JSON when
  provided. Absent when `--meta` was not passed (preserves the legacy
  payload exactly for consumers that didn't ask for it).
- `exited`: optional `reason` (String) — one of
  `"success"|"failure"|"timeout"|"disconnected"`. Present from this plan
  onward; absent in pre-existing fixtures, which v1 consumers must
  tolerate (additive contract).

### Layer 2 coexistence
This plan does **not** define `resume`, `log_active`, `log_idle`, or
`compaction` — those names remain reserved for the watcher's eventual
producers. The session aggregator does, however, *count* events of those
types between `started` and `exited` to populate
`actual.force_resumes`/`stalls`/`compactions`/`disconnections` in the
consolidated record. If Layer 2 hasn't shipped yet, the counters stay at
`0` (cleanly degrades).

### Consolidated summary record
One JSON object per line, appended to the path resolved from `--summary-out`
(or the default `<repo_root>/koder/DISPATCH.jsonl`). Shape matches
`holm/koder/DISPATCH.schema.md` exactly. Keys harnex always populates:

- `meta.id`, `meta.tmux_session` (= id), `meta.started_at`, `meta.ended_at`,
  `meta.harness`, `meta.harness_version`, `meta.agent` (= adapter.key),
  `meta.host`, `meta.platform`, `meta.repo`, `meta.branch` (when git ok),
  `meta.start_sha` / `meta.end_sha` (when git ok)
- `meta.description` (from `--description`) if set
- `meta.task_brief` left `null` (not derivable; consumer can pass via `--meta`)
- `meta.orchestrator`, `meta.orchestrator_session`, `meta.chain_id`,
  `meta.parent_dispatch_id`, `meta.tier`, `meta.phase`, `meta.issue`,
  `meta.plan` — all from `--meta` passthrough; default `null`
- `meta.agent_version`, `meta.agent_provider`, `meta.agent_deployment` —
  `null` in v1 (codex does not advertise these on stdout; deferred)
- `predicted` — verbatim from `--meta.predicted` if present, else `{}`
- `actual.model`, `actual.effort` — from `--meta.model`/`--meta.effort` if
  present, else `null` (could differ from `predicted` if the orchestrator
  overrode mid-flight; v1 trusts the meta value)
- `actual.duration_s` — `(ended_at - started_at).to_i`
- `actual.input_tokens` / `output_tokens` / `reasoning_tokens` /
  `cached_tokens` — from adapter parse, else `null`
- `actual.cost_usd` — always `null` (Q5)
- `actual.loc_added` / `loc_removed` / `files_changed` / `commits` — from
  git capture, else `null`
- `actual.exit` — `"success"` (exit 0 + summary parsed), `"failure"`
  (exit ≠ 0), `"timeout"` (force-stop via watcher escalation), or
  `"disconnected"` (exit 0 but no summary block)
- `actual.stalls` / `force_resumes` / `disconnections` / `compactions` —
  counts from typed events on the bus during this session
- `actual.tests_run` / `tests_passed` / `tests_failed` — `null` in v1

## File-by-file changes

| File | Change |
|---|---|
| `lib/harnex/core.rb` | + `default_summary_out_path(repo_root)` (returns `<repo>/koder/DISPATCH.jsonl` if dir exists else `nil`); + `strip_ansi(text)` helper (regex `/\e\[[0-9;]*[a-zA-Z]/`); + `git_capture_start(repo_root)` + `git_capture_end(repo_root, start_sha)` (rescue StandardError ⇒ `{}`); + `host_info` returning `{host:, platform:}`; + `harness_version` constant load. |
| `lib/harnex/adapters/base.rb` | + `parse_session_summary(transcript_tail) ⇒ {}` default. |
| `lib/harnex/adapters/codex.rb` | + `parse_session_summary` implementation with the two regexes (token line + resume UUID); strip commas before `Integer(...)`; return hash with nil for unmatched fields. |
| `lib/harnex/runtime/session.rb` | accept new ctor kwargs `meta:` (parsed Hash or `nil`), `summary_out:` (path or `nil`); on `started` emit, attach `meta:` payload when provided; after `started` emit, run `git_capture_start` and emit `git` event; in the exit path, before `exited`: read last 16 KB of output log → strip ANSI → `adapter.parse_session_summary` → emit `usage`; run `git_capture_end` → emit `git phase:end`; classify exit reason; build & append consolidated record to `summary_out`; emit `summary` event with that path; finally emit `exited` with `reason`. Add private `EventCounters` aggregator that tails the events log between `started` and `exited` to produce `force_resumes/stalls/disconnections/compactions`. |
| `lib/harnex/commands/run.rb` | + `--meta JSON` (parse with `JSON.parse`, raise `OptionParser::InvalidOption` on failure); + `--summary-out PATH` (override default); pass both into `Session.new`; for `--detach`/`--tmux` spawn paths, forward both flags through the rebuilt argv (mirror existing `--description` plumbing). |
| `lib/harnex/cli.rb` | help text additions (mirror existing flag block). |
| `docs/events.md` | new section "Layer 5: dispatch telemetry" — document `usage`, `git`, `summary` event shapes; document new optional fields on `started.meta` and `exited.reason`; reaffirm v1 additive promise. |
| `docs/dispatch-telemetry.md` | new file — explain `--meta` shape, `--summary-out` resolution, the consolidated record contract, the always-`null` cost field, the failure-mode taxonomy. |

LoC budget (production): ~180-260. Tests: ~140-200. Docs: ~80-140.

## Test plan

One bullet per acceptance criterion, plus concrete files.

- **CLI flags accepted.** `test/harnex/commands/run_test.rb` — `--meta '{"a":1}'`
  parses, invalid JSON exits non-zero with clear error; `--summary-out PATH`
  overrides default; default resolves to `<repo>/koder/DISPATCH.jsonl` when
  `koder/` exists, `nil` otherwise.
- **Session-end events emitted.** `test/harnex/runtime/session_test.rb` —
  on a mock adapter whose transcript ends with the codex marker, `usage`
  event has the expected token counts and `agent_session_id`; `git`
  start+end events present (in a temp git repo fixture); `summary` event
  carries the resolved path; `exited.reason == "success"`.
- **Consolidated record written.** Same test file — appended JSONL line
  parses, has top-level `meta`/`predicted`/`actual`, fields populated per
  the schema, `cost_usd` is `null`, `tests_*` are `null`.
- **Predicted passthrough with and without metadata.** Two cases:
  with `--meta {"predicted":{"input_tokens":[1,2]}}` predicted block round-
  trips; without `--meta` predicted block is `{}` and meta fields harnex
  owns are still populated.
- **Non-extractable nullability.** Adapter returning `{}` (no summary in
  transcript) yields `usage` event with all token fields `null`, consolidated
  record `actual.input_tokens` etc. all `null`, `actual.exit ==
  "disconnected"`.
- **Schema additive-only check.** `test/fixtures/events_v1.jsonl` extended
  with one example per new type; existing v1 fixture assertions still pass
  (no removed/renamed fields). New fields validated against an "expected
  keys ⊇ legacy keys" check.
- **No-regression.** Full suite `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'` stays green (currently 235 tests, target 250+).
- **Existing dispatches unchanged.** Run a session without `--meta`/`--summary-out`
  in a non-git directory: events stream contains `started`/`send`/`exited`
  plus the new `usage`/`summary` events (no `git` events when git unavailable),
  no summary file written when no path resolves, exit code unchanged.
- **Codex adapter parser unit test.** `test/harnex/adapters/codex_test.rb` —
  fed the literal marker line, returns the expected hash; fed garbage,
  returns hash with all-nil fields; comma-separated numbers parse.

## Phases

### Phase 1: predicted intake + meta plumbing
1. Add `--meta JSON` to `Run` with strict `JSON.parse` validation.
2. Pass `meta:` through to `Session` ctor; attach to `started` event.
3. Extend tests for help/usage and meta echo on the `started` event.

### Phase 2: actual extraction
1. Add `parse_session_summary` to `adapters/base.rb` (no-op default).
2. Implement the codex regex parser with comma-stripping and UUID capture.
3. Add `Harnex.strip_ansi`, `git_capture_start`, `git_capture_end`,
   `host_info`, `harness_version` helpers in `core.rb`.
4. In `Session#run`, after PTY exit and before the existing `exited` emit:
   read last 16 KB of `output_log_path`, strip ANSI, parse, emit `usage`.
5. Emit `git` start (after `started`) and `git` end (before `exited`).
6. Add adapter parser unit tests + session-level usage/git event tests.

### Phase 3: summary writer + exit classification
1. Add `--summary-out PATH` to `Run` with default-resolution helper.
2. Build `EventCounters` (in-process tally over emitted events) for
   `stalls/force_resumes/disconnections/compactions`.
3. Build the consolidated record (`meta`/`predicted`/`actual`); append to
   the resolved path; emit the `summary` event with that path.
4. Classify `actual.exit` from exit code + summary-parse outcome + watcher
   escalation flag; attach to `exited.reason`.
5. Tests: full record round-trip, predicted with/without `--meta`,
   nullability when extraction failed, default-path resolution, summary
   write best-effort failure (chmod 0444 the dir, ensure no crash).

### Phase 4: docs + fixture
1. Extend `docs/events.md` with the Layer 5 section.
2. Add `docs/dispatch-telemetry.md` covering `--meta`, `--summary-out`, the
   consolidated record, the always-null cost field, failure modes.
3. Extend `test/fixtures/events_v1.jsonl` with `usage`, `git`, `summary`
   examples; ensure schema test still passes.
4. Run full suite; verify 250+ tests pass.

## Out of scope
(Restated from issue #23.)

- Calibration / analysis of the resulting JSONL — deferred to consumer
  until ~10 records exist.
- Predicted range population in any consumer's recommendations table.
- Cost ceiling enforcement / dispatch refusal.
- Per-model pricing table inside harnex (`actual.cost_usd` always `null`).
- Multi-agent (claude / aider) summary parsing — codex first; the
  adapter-base hook keeps the door open for follow-up work without a
  schema change.
- Retroactive ingestion of older sessions (transcripts may not exist).
- Detection of test-run counts (`tests_run`/`tests_passed`/`tests_failed`
  always `null` in v1).
- Closing the Layer 2 watcher debt (`resume`/`log_active`/`log_idle`
  producers); this plan reserves the names and consumes them if present
  but does not implement them.

## Open questions (non-blocking)
1. Should `agent_version` be sniffed from the codex banner line (`OpenAI
   Codex` plus version) instead of left `null`? Cheap addition but parser
   surface grows; defer until a consumer asks.
2. Should the summary writer use `flock(2)` to serialize concurrent
   appenders (multiple harnex sessions in one repo writing the same
   `DISPATCH.jsonl`)? POSIX append is atomic for ≤PIPE_BUF lines and our
   records are ~1-2 KB, so likely fine — call out in docs and revisit if
   a consumer reports interleaving.
3. Should `--meta` accept `@/path/to/file.json` for long payloads?
   Probably yes in a follow-up; v1 keeps the surface minimal.
