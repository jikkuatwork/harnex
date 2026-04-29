# Plan 26: `harnex events` JSONL Stream (Layer 4 of #22)
Issue: #22 (Layer 4)
Date: 2026-04-29
Depends on: none (must integrate cleanly with Layer 2 later)

## Goal
Add `harnex events --id <ID>` as a blocking JSONL stream for orchestrators.
Layer 4 remains thin and independently shippable:
- ship an events transport + v1 schema contract
- emit `started` / `send` / `exited` now
- define how Layer 2 later emits `resume` / `log_*` into the same bus

## Scope guardrails
In scope:
- new `events` command + CLI wiring
- per-session event transport
- v1 schema and compatibility promise
- runtime emission points (start/send/exit)
- tests + fixture for schema stability
Out of scope:
- watcher logic from Layer 2 (`--watch`, stall policy, resume policy)
- preset logic from Layer 3
- pane/disconnect heuristics

## Event bus mechanism decision (required)
### Option A: file-backed JSONL bus (recommended)
Design:
- append event objects to
  `~/.local/state/harnex/events/<repo_key>--<id_key>.jsonl`
- `harnex events` prints snapshot, then tails appended lines in follow mode
Pros:
- simplest fit with existing `harnex logs` transcript pattern
- multi-subscriber by default (N readers can tail one file)
- crash-safe replay for reconnecting orchestrators
- no API-server streaming surface to maintain
Cons:
- extra state file per session
- replay filtering is consumer-side

### Option B: API pub/sub (long-poll/SSE)
Pros:
- direct push stream semantics
- no additional state file
Cons:
- higher complexity (fanout, disconnect/reconnect, replay window)
- weak crash semantics unless persistence is added anyway
- bigger risk for stdlib-only implementation

### Decision
Use Option A (file-backed JSONL).
Reasoning: lowest implementation risk, strongest replay behavior, and clean
alignment with current harnex data model.

## v1 schema + stability policy
Each JSONL row is one event object.
Common envelope (required on every event):
- `schema_version` (Integer): `1`
- `ts` (String): UTC ISO-8601 timestamp
- `id` (String): session ID
- `type` (String): event kind
Event payloads:
- `started`: `{..., type:"started", pid}`
- `log_active`: `{..., type:"log_active", age_s:0}`
- `log_idle`: `{..., type:"log_idle", age_s:N}`
- `send`: `{..., type:"send", msg, forced:bool}`
- `resume`: `{..., type:"resume", attempt:N}`
- `exited`: `{..., type:"exited", code:N, signal:"..."}`
Compatibility promise:
- v1 changes are additive only
- no remove/rename/type-change of existing fields without major bump
Versioning recommendation:
- include `schema_version` on every row (not header-only) so `--from` replay
  from middle-of-file stays self-describing.

## Command surface: `harnex events`
Required:
- `--id <ID>` required
- `--follow` default true
- `--snapshot` = non-blocking dump (`--no-follow` alias behavior)
- `--from <ts>` replay floor (`ts >= from`)
Recommended parity flags:
- `--repo <PATH>` (default: current repo)
- `--cli <CLI>` optional filter on live lookup
- `-h/--help`
Exit behavior:
- follow mode exits `0` when target `exited` event is observed
- if target already exited, print snapshot and exit `0`
- if stream source drops unexpectedly (missing/truncated file), exit `1`
- invalid `--from` parse => exit `1` with clear error
Timestamp parsing:
- v1 accepts ISO-8601 (`Time.iso8601`)
- rejects ambiguous free-form date strings

## Emission integration points
### Runtime emits in Layer 4
`Session` appends events at:
- start: emit `started` after PTY spawn (PID known)
- send: emit `send` after successful adapter injection
- exit: emit `exited` after exit code/signal resolved
Field mapping:
- `send.msg` = original send text
- `send.forced` = send force flag
- `exited.code` = existing synthesized numeric code
- `exited.signal` included only for signaled exits

### Layer 2 contract (interface only)
Layer 4 defines the bus contract; Layer 2 later publishes:
- `resume` on each auto-resume attempt (`attempt` monotonic)
- `log_active` / `log_idle` from its activity monitor loop
Layer 4 must not design or implement Layer 2 watcher policy.

## Exact file inventory + LoC budget
Production code target (~80-110 LoC):
- `lib/harnex/core.rb` (+8 to +20)
  - add `events_log_path(repo_root, id)` helper
- `lib/harnex/runtime/session.rb` (+35 to +55)
  - add event append helper + start/send/exit emit hooks
- `lib/harnex/commands/events.rb` (+70 to +110, new)
  - parse options, snapshot replay, follow tail loop, `--from` filter
- `lib/harnex/cli.rb` (+10 to +16)
  - dispatch/help/usage wiring for `events`
- `lib/harnex.rb` (+1)
  - require `commands/events`
Tests + fixtures (~120-180 LoC):
- `test/harnex/commands/events_test.rb` (+90 to +140, new)
- `test/harnex/runtime/session_test.rb` (+25 to +45)
- `test/harnex/cli_test.rb` (+8 to +15)
- `test/fixtures/events_v1.jsonl` (+6 to +12, new)
Docs (~40-80 LoC):
- `docs/events.md` (+40 to +80, new)

## Implementation phases
## Phase 1: transport + runtime hooks
1. Add `events_log_path` in `core.rb`.
2. Extend `Session` with append-only JSONL event writer.
3. Emit `started`, `send`, `exited` at the defined points.
4. Flush per event to minimize loss on abrupt exit.

## Phase 2: `events` command
1. Add `Harnex::Events` command.
2. Resolve target by repo/id/cli (same lookup style as `logs`).
3. Snapshot read + optional `--from` filtering.
4. Follow mode tail until `exited` event for target.
5. Handle subscription drop with explicit non-zero exit.
6. Wire into `CLI` and help text.

## Phase 3: fixture + docs
1. Add `test/fixtures/events_v1.jsonl` with one example per event type.
2. Add schema assertions against fixture required keys.
3. Add `docs/events.md` with v1 schema + stability contract.

## Test plan (minimum required + concrete cases)
Required by brief:
1. start+exit round-trip
2. send event captured
3. schema fixture asserts field set
Concrete tests:
- `test/harnex/runtime/session_test.rb`
  - start emits `started`; shutdown emits `exited`
  - send path emits `send` with `msg` + `forced`
- `test/harnex/commands/events_test.rb`
  - snapshot prints existing JSONL in order
  - follow exits when `exited` appears
  - `--from` filters older events
  - stream/source drop exits non-zero
  - fixture schema validation by `type`
- `test/harnex/cli_test.rb`
  - `help events` usage path
  - top-level help lists `events`

## Verification commands
- `ruby -Ilib -Itest test/harnex/runtime/session_test.rb`
- `ruby -Ilib -Itest test/harnex/commands/events_test.rb`
- `ruby -Ilib -Itest test/harnex/cli_test.rb`
- `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`

## `docs/events.md` outline (sections only)
1. Purpose and non-goals
2. CLI usage (`--id`, `--follow`, `--snapshot`, `--from`)
3. Transport and event file location
4. v1 schema reference (envelope + per-type payloads)
5. Stability promise (additive-only in v1)
6. Consumer patterns (`jq`, reconnect + replay)
7. Layer 2 integration note (`resume` and `log_*` producers)

## Acceptance checklist
- [ ] `harnex events --id <ID>` exists and is visible in help/usage
- [ ] per-session JSONL event transport exists under harnex state dir
- [ ] runtime emits `started` / `send` / `exited`
- [ ] schema includes `schema_version` and v1 stability policy
- [ ] follow mode blocks and exits on `exited`
- [ ] snapshot mode is non-blocking
- [ ] `--from <ts>` replay filtering works
- [ ] required tests pass, including schema fixture checks
- [ ] `docs/events.md` documents v1 contract

## Open Questions
1. **Ship now vs defer:** should Layer 4 ship immediately after L1-L3, or stay
   deferred until a second concrete consumer exists (mapping recommends defer)?
2. Should `send.msg` contain full text or a bounded preview for privacy/noise?
3. If Layer 2 owns `log_*`, should `harnex events` remain read-only forever?
4. Do we need a `seq` field in v1 for strict same-timestamp ordering?
