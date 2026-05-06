---
issue: 27
plan: 28
tier: A
created: 2026-05-06
phases: 5
---

# Plan 28: Codex `app-server` adapter (Issue #27)

## Goal

Replace the pane-scraping Codex adapter with a JSON-RPC adapter that
talks to a spawned `codex app-server` over stdio. Surface
`turn/completed` and `error` natively, retire the heuristic state
machine for Codex, and ship as harnex 0.6.0. Closes Issues #22 (Codex
side), #24, #25 by construction.

The "what" is canonical in `koder/issues/27_codex_appserver_adapter.md`.
This plan owns "how, in what order, with what tests."

## Reference pin

- `codex-plugin-cc` @ `807e03ac9d5aa23bc395fdec8c3767500a86b3cf`
- Min Codex CLI: `0.128.0` (verified locally on 2026-05-06)
- Schema regenerated 2026-05-06 — all notification methods Issue #27
  enumerates (`turn/started`, `turn/completed`, `error`, `item/started`,
  `item/completed`, `thread/started`, `thread/status/changed`,
  `account/*`) are present. **No drift from Issue #27.** Extras like
  `turn/diff/updated`, `turn/plan/updated`,
  `thread/tokenUsage/updated`, `account/rateLimits/updated` are
  available — Phase 5 notes which we adopt opportunistically.

## Scope decisions (locked here, per scratch hygiene items)

1. **Schema regen first.** Phase 1's first task is
   `codex app-server generate-json-schema --out /tmp/codex-schema-X` and
   diffing against the checked-in fixture. Drift fails CI.
2. **Event naming: Option B.** Keep `task_complete` as the harnex-side
   event name; populate from `turn/completed`. Rationale: existing
   tests/scripts/orchestrators are wired to `task_complete`; the event
   taxonomy is adapter-agnostic; renaming would churn `claude` and
   `generic` emitters too. New event types added: `turn_started`,
   `item_completed`, plus `disconnected` populated from `error`
   notifications (consistent with the existing disconnect counter at
   `runtime/session.rb:28`).
3. **Release artifacts in Phase 5.** Version bump, `CHANGELOG.md`
   creation, `harnex doctor` Codex preflight.
4. **`--legacy-pty` is per-invocation CLI flag** at `harnex run`. Not
   env, not config file. Debuggable in `ps`, can't carry over from
   stale state.
5. **Test fixtures <50 KB.** Hand-extracted slices, not full bundle
   (full is 1.27 MB). Subset spec in Phase 1.

## Adapter contract — extending `Base`

`Base` (`lib/harnex/adapters/base.rb:1`) is built around screen-text
parsing — `input_state(text)`, `wait_for_sendable`,
`build_send_payload`. None of these apply to RPC, but the `key` /
`base_command` / `infer_repo_path` / `parse_session_summary` surface
still does.

**Decision:** subclass `Base` and override aggressively rather than
introduce a parallel adapter hierarchy. Override `input_state` to
return state from the JSON-RPC client (`prompt` when no turn in flight,
`busy` while a turn is open, `disconnected` after an `error`). Override
`build_send_payload` to no-op — `Session#inject_via_adapter` should
route through a new path.

**New methods on the adapter** (forward-compat with future
non-PTY adapters; document on `Base` as optional):

- `transport` → `:stdio_jsonrpc` (default `:pty` on Base) — lets
  `Session` pick the right injection path.
- `start_rpc(env:, cwd:)` → spawns subprocess, runs handshake, starts
  read thread. Returns when ready.
- `dispatch(prompt:, model:, effort:)` → opens a turn; returns
  `turn_id`.
- `interrupt(turn_id:)` → `turn/interrupt`.
- `resume(thread_id:)` → `thread/resume`.
- `on_notification(&block)` → register a single callback for all
  pass-through notifications (`Session` registers one that fans out to
  `emit_event`).
- `describe` → returns `{transport:, methods:, notifications:,
  events:}` Hash. Deferred to Phase 5; cheap to add and removes future
  doc duplication for Lane Skills (holm #271).

`Base` gains a default `transport :pty` and a default `describe`
returning `{transport: :pty}`. No behavior change for `claude` /
`generic` / legacy `codex.rb`.

## JSON-RPC handshake

Mirrors `codex-plugin-cc/plugins/codex/scripts/lib/app-server.mjs:188`:

```ruby
request("initialize", {
  clientInfo: {
    title: "harnex",
    name:  "harnex",
    version: Harnex::VERSION
  },
  capabilities: {
    experimentalApi: false,
    optOutNotificationMethods: %w[
      item/agentMessage/delta
      item/reasoning/summaryTextDelta
      item/reasoning/summaryPartAdded
      item/reasoning/textDelta
    ]
  }
})
notify("initialized", {})
```

Wire format: one JSON object per line on stdin/stdout. Read loop is a
dedicated Ruby thread doing line-buffered `readpartial` + `JSON.parse`.
Pending-request map keyed by `id` resolves on response; everything else
fans out to the notification handler.

## Notification → event mapping

| Server notification         | harnex event       | Notes |
|-----------------------------|--------------------|-------|
| `thread/started`            | (metadata only)    | Stash `threadId` on session |
| `turn/started`              | `turn_started`     | New event type; carries `turnId` |
| `turn/completed`            | `task_complete`    | Option B; carries `turnId`, `status`, `tokenUsage` if present |
| `item/started`              | (silent)           | Available via `events --raw` follow-up if needed |
| `item/completed`            | `item_completed`   | New event type; surfaces tool calls + assistant messages |
| `error`                     | `disconnected`     | Increments existing `disconnections` counter at `runtime/session.rb:28` |
| `thread/status/changed`     | (state only)       | Drives `agent_state` |
| `thread/tokenUsage/updated` | `usage` (live)     | Phase 5; replaces post-hoc transcript regex in `codex.rb:63` |
| `account/rateLimits/updated`| (silent, status)   | Phase 5; surfaces in `status --json` |

Streaming deltas are opted out via `optOutNotificationMethods`. Don't
persist them as events.

## Phase 1 — JSON-RPC client + handshake

**Goal:** `lib/harnex/adapters/codex_appserver.rb` boots a real
`codex app-server`, completes `initialize` + `initialized`, and shuts
down cleanly on close.

**Files:**
- `lib/harnex/adapters/codex_appserver.rb` — new, ~120 LOC at end of
  phase. Holds:
  - `JsonRpcClient` (private inner class, ~70 LOC): `request(method,
    params)` returning a value (synchronous via Queue), `notify`,
    `on_notification`, `start`, `close`, line-buffered read loop.
  - `CodexAppServer < Base` skeleton: `transport :stdio_jsonrpc`,
    `base_command`, `start_rpc`, no-op `build_send_payload`.
- `lib/harnex/adapters.rb` — add registry entry but **gated** behind a
  feature flag `Harnex::Adapters.codex_appserver_enabled?` (reads
  `HARNEX_CODEX_APPSERVER` env). Phase 3 flips the default.
- `test/harnex/adapters/test_codex_appserver_handshake.rb` — new.
  Stubs the subprocess with `IO.pipe` pair; asserts `initialize` is
  sent, response unblocks `start_rpc`, `initialized` notification
  follows, read thread joins on close.
- `test/fixtures/codex_appserver/handshake.jsonl` — new, ~1 KB. Two
  lines: response to `initialize`, then EOF.

**Schema fixture subset** (committed under
`test/fixtures/codex_appserver/schema/`, target ≤50 KB total):

- `ServerNotification.subset.json` — keep only the `oneOf` branches
  for: `error`, `thread/started`, `thread/status/changed`,
  `turn/started`, `turn/completed`, `item/started`, `item/completed`,
  `thread/tokenUsage/updated`. Strip definitions only used by other
  branches.
- `ClientRequest.subset.json` — keep only the request methods we
  issue: `initialize`, `thread/start`, `turn/start`, `turn/interrupt`,
  `thread/resume`. Strip the rest.

A `rake fixtures:codex_schema` task (or `bin/dev/regen-codex-schema`
script — pick one in impl) regenerates these from the live schema and
prunes. CI runs the regen and `git diff --exit-code` against the
fixtures. Drift = failed build = explicit human review.

**Commit:** `feat(plan-28-1): codex app-server JSON-RPC client +
handshake`.

## Phase 2 — Thread + turn lifecycle

**Goal:** Adapter exposes `dispatch`, `interrupt`, `resume`, and emits
notifications to a registered handler.

**Files:**
- `lib/harnex/adapters/codex_appserver.rb` — extend to ~200 LOC:
  - `dispatch(prompt:, model: nil, effort: nil)`: `thread/start` (if
    no thread yet), then `turn/start` with
    `input: { content: [{type: "text", text: prompt}] }` per the
    current `ClientRequest` schema (verify exact shape against
    `ClientRequest.subset.json` during impl).
  - `interrupt`, `resume` thin wrappers.
  - `state`: returns `:prompt` / `:busy` / `:disconnected` based on
    open turn + last error.
  - `input_state(_)` override: ignores screen text, returns
    `{state: state.to_s, input_ready: state == :prompt}`.
- `test/harnex/adapters/test_codex_appserver_lifecycle.rb` — three
  scenarios driven by scripted stdio fixtures:
  1. **Golden turn:** dispatch → `turn/started` → `item/completed`
     ×2 → `turn/completed`. Assert handler receives all four; final
     state is `:prompt`.
  2. **Interrupt mid-turn:** dispatch → `turn/started` →
     `interrupt(turn_id)` → `turn/completed{status: "interrupted"}`.
  3. **Error notification:** dispatch → `error` → state becomes
     `:disconnected`; subsequent dispatch raises until `resume`.

**Commit:** `feat(plan-28-2): thread + turn lifecycle, notification
fanout`.

## Phase 3 — Wire into runtime + `--legacy-pty`

**Goal:** `harnex run codex` uses the new adapter by default.
`harnex run codex --legacy-pty` falls back to the existing
`Adapters::Codex`. Notifications flow into the existing events log.

**Files:**
- `lib/harnex/commands/run.rb` — add `--legacy-pty` flag (boolean,
  default false). When `cli == "codex"`, pick adapter accordingly.
  Document in the command help text.
- `lib/harnex/adapters.rb` — flip `"codex"` registry to
  `CodexAppServer` by default; legacy class accessible via
  `Adapters.build("codex", argv, legacy_pty: true)`. Update
  `Adapters.build` signature; add a kwarg with default `false`.
- `lib/harnex/runtime/session.rb` — branching on
  `adapter.transport`:
  - `:pty` → existing path (no change for `claude` / `generic` /
    legacy codex).
  - `:stdio_jsonrpc` → new `run_jsonrpc` method that:
    - Spawns subprocess via the adapter (no PTY, no winsize sync, no
      stdin raw mode).
    - Wires `adapter.on_notification` to a handler that calls
      `emit_event(...)` per the mapping table above.
    - `inject_via_adapter` becomes `adapter.dispatch(prompt: text,
      ...)` for the new transport.
    - `inject_stop` becomes `adapter.interrupt(turn_id)` plus
      subprocess termination.
    - Output log still receives a transcript — synthesized from
      `item/completed` text payloads (preserves `harnex logs`
      compatibility).
  - Existing `EventCounters` taxonomy unchanged. `error` notification
    triggers `record("disconnect")` so the existing
    `disconnections` field at `runtime/session.rb:28` still
    populates.
- `lib/harnex/core.rb:355` — `Adapters.build` call site picks up the
  new kwarg.
- `test/harnex/runtime/test_session_jsonrpc.rb` — end-to-end against
  scripted stdio: dispatch a fixture prompt, assert
  `events_log_path` contains `task_complete` and the file's content
  for `harnex logs` is non-empty.
- **One real integration test** behind a `CODEX_INTEGRATION=1`
  guard (skip otherwise so the suite stays hermetic): spawn real
  `codex app-server`, send "Write a one-line poem about clouds. Then
  stop.", assert `task_complete` arrives within 30s.

**Commit:** `feat(plan-28-3): wire codex_appserver into Session;
--legacy-pty fallback`.

## Phase 4 — `harnex wait --until task_complete` + status fields

**Goal:** A first-class wait predicate keyed on `task_complete`, and
new `status --json` fields fed by RPC notifications.

**Files:**
- `lib/harnex/commands/wait.rb` — extend the existing `--until`
  parser. Predicates supported in this phase: `exit` (existing),
  `task_complete` (new), `prompt` (new — fires on
  `agent_state == "prompt"` after at least one `task_complete`).
  Implementation: tail the events JSONL via the existing watcher
  backend (`lib/harnex/watcher.rb`), break on match. Adapter-agnostic
  — works for `claude` / `generic` too if they emit `task_complete`
  in the future.
- `lib/harnex/runtime/session.rb` — extend `status_payload`:
  - `last_completed_at` — ISO8601 of last `turn/completed`.
  - `model` — from `meta_hash["model"]` if set on dispatch (existing
    plumbing); echo from `thread/started` params if present.
  - `effort` — same source.
  - `auto_disconnects` — same as existing `disconnections` counter,
    surfaced into status (currently lives only in summary JSON).
- `test/harnex/commands/test_wait_until_task_complete.rb` — new.
  Pre-seeds an events JSONL with `started`, `task_complete`, asserts
  `wait --until task_complete` returns 0 immediately. Second test:
  starts wait against a still-empty file, appends `task_complete`,
  asserts wait unblocks within 1s.
- `test/harnex/runtime/test_status_jsonrpc_fields.rb` — new.

**Commit:** `feat(plan-28-4): harnex wait --until task_complete +
status fields`.

## Phase 5 — Release artifacts (0.6.0)

**Goal:** ship-ready 0.6.0 with version, changelog, doctor preflight,
docs, and Issues #22 (Codex side) / #24 / #25 flipped.

**Files:**
- `lib/harnex/version.rb` — bump to `"0.6.0"`; update
  `RELEASE_DATE`.
- `CHANGELOG.md` — **create** (does not exist today). First entry:

  ```
  ## 0.6.0 — 2026-MM-DD

  ### Architectural pivot: Codex on JSON-RPC

  harnex now speaks `codex app-server` JSON-RPC over stdio for the
  Codex adapter. Pane-scraping is retired for Codex. Closed by
  construction:

  - #22 (Codex side; --watch --stall-after still applies to
    claude/generic)
  - #24 (disconnect detection — `error` notifications replace regex)
  - #25 (first-class completion signal — `turn/completed` is it)

  ### New

  - `harnex wait --until task_complete` — block until a turn
    completes. Example: `harnex wait --id cx-i-242 --until
    task_complete`.
  - `harnex status --json` includes `last_completed_at`, `model`,
    `effort`, `auto_disconnects`.
  - `harnex doctor` preflight checks Codex CLI ≥ 0.128.0.

  ### Migration

  - Codex CLI ≥ 0.128.0 required.
  - Existing `harnex run codex ...` invocations work unchanged.
  - Emergency fallback: `harnex run codex --legacy-pty ...` (the
    pre-0.6.0 PTY adapter). Deprecated; will be removed in 0.7.0.

  ### Cross-repo

  - Resolves holm #201 from the harnex side. holm #271 (substrate v2
    meta) tracks the broader pivot.
  ```

- `lib/harnex/commands/doctor.rb` (or `lib/harnex/doctor.rb` — pick
  during impl based on existing CLI structure; if no `doctor`
  command exists yet, add one): Codex preflight — runs
  `codex --version`, parses, errors clearly if `< 0.128.0`. Risk #3
  in Issue #27.
- `docs/codex-appserver.md` — new. Covers: transport, handshake,
  notification mapping, `--legacy-pty` escape hatch, troubleshooting
  (e.g. "what to check if `task_complete` doesn't fire" — mostly
  "your Codex is too old"). Examples use short-form session codes
  (`cx-i`, `cx-p`, `cx-r`, `cx-f`, `cx-cr`, `cx-cf`, `cx-m`) per holm
  conventions.
- `TECHNICAL.md` — replace the pane-scraping description of the
  Codex adapter with a pointer to the JSON-RPC contract.
- `koder/issues/22_built_in_dispatch_monitoring.md`,
  `24_disconnect_detection.md`, `25_first_class_completion_signal.md`
  — flip status to `closed` with a one-line note referencing 0.6.0.
- `Adapter#describe` lands here (cheap; reads from a local
  constant). Returns `{transport: :stdio_jsonrpc, request_methods:
  [...], notification_methods: [...], events: [...]}`. Forward-compat
  with Lane Skills (holm #271).
- Optional Phase 5 stretch (drop if approaching 500 LOC budget, defer
  to follow-up): live `usage` events from
  `thread/tokenUsage/updated` and `rate_limits` field in status from
  `account/rateLimits/updated`.

**Commit:** `release(plan-28-5): harnex 0.6.0 — Codex app-server
adapter`.

Tag + push: `gem build harnex.gemspec && bin/gem-push
harnex-0.6.0.gem` per `CLAUDE.md` release notes. **Do not** read
`.env` directly.

## Test strategy

- **Unit:** stdio fixtures (small JSONL files) exercise the
  client/adapter without a real subprocess. Standard pattern: an
  `IO.pipe` stand-in; tests write fixture lines to the read side and
  assert the adapter's response on the write side.
- **Integration:** one real `codex app-server` test gated on
  `CODEX_INTEGRATION=1`. Hermetic suite stays hermetic by default; CI
  can opt in.
- **Schema-drift gate:** CI step runs
  `codex app-server generate-json-schema`, prunes via the same
  script that generated the fixture, asserts `git diff --exit-code`.
  Drift gates the build.
- **Backward-compat:** the existing `claude` / `generic` /
  `--legacy-pty codex` test suites must remain green untouched. Phase
  3 explicitly verifies this — no edits to `claude.rb`,
  `generic.rb`, or `codex.rb` (legacy).

## What this plan deliberately does not do

- No broker / multiplexing (codex-plugin-cc's `BrokerCodexAppServerClient`
  pattern). v1 is spawn-per-session. Defer to a follow-up issue if
  contention emerges.
- No WebSocket transport. stdio only.
- No `claude` adapter replatform (no app-server equivalent).
- No `harnex done` worker-side callback (Issue #25's Option B). The
  RPC obviates it; if a use case emerges where workers want to send
  early/explicit completion, file separately.
- No Lane Skills implementation. `Adapter#describe` lands as the
  hook; holm #271 owns the consumer.
- No `IDLE` / `WORK_IDLE` rename (Issue #25 quirk). Pane focus events
  no longer drive state for Codex under the new transport, so the
  quirk is moot for the affected adapter. `claude` / `generic` keep
  the existing semantics.

## Risks reframed for this plan

| Risk | Plan response |
|------|---------------|
| Schema drift between Codex versions | CI regen + diff gate (Phase 1). Bump = explicit PR. |
| `--legacy-pty` rot | Deprecation note in 0.6.0 CHANGELOG; remove in 0.7.0. Tests for legacy path stay until then. |
| RPC subprocess hangs / never EOFs | Read thread has a `Process.waitpid(pid, Process::WNOHANG)` heartbeat; close path always sends SIGTERM after `stdin.close` + 50ms (mirrors `app-server.mjs:242`). |
| Adapter base extension breaks `claude` / `generic` | New methods are optional with `Base` defaults; existing adapters get `transport :pty` for free. Phase 3 runs the full pre-existing suite. |

## LOC budget check

Adapter (~200 LOC) + Session branch (~80 LOC) + wait predicate
(~40 LOC) + doctor (~30 LOC) + status fields (~20 LOC) + tests
(~250 LOC across phases) + docs/CHANGELOG (~150 LOC) ≈ 770 LOC of
non-fixture impl. Plan ceiling here is plan-Markdown ≤500 LOC, not
impl LOC; impl is in the implementer's hands within phase scope.
