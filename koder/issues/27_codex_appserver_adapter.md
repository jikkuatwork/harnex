---
status: open
priority: P1
created: 2026-05-06
tags: dispatch,monitoring,resilience,codex,architecture
---

# Issue 27: Replatform Codex adapter onto `codex app-server` (JSON-RPC transport)

## Status

**Open. P1.** Filed 2026-05-06 after a substrate-audit session in
`holmhq/holm` that revealed the architecturally correct fix for our
recurring pain points: stop scraping tmux panes for state and start
talking to Codex's own structured RPC.

This issue **supersedes** the originally-planned point fixes:

- `22_built_in_dispatch_monitoring.md` (was: fixed) — Codex side reframed:
  the log-mtime + bounded-resume work still applies for `claude` and
  `generic` adapters; for Codex it becomes obsolete (see "What this
  closes" below).
- `24_disconnect_detection.md` — closed by construction.
- `25_first_class_completion_signal.md` — closed by construction.

Sister: `23_dispatch_telemetry.md` (open) — still relevant; counters
become trivial to populate from app-server notifications instead of
from inferred pane state.

## The architectural problem

Every harnex Codex pain point in the last six weeks traces to the same
root: we infer Codex's state by scraping `tmux capture-pane` output and
matching prompt prefixes / banner strings / disconnect markers.

Every layer of fix we've stacked on top still loses on edge cases:

- `@banner_seen` latch (codex.rb:39–57) loses the banner when a
  `■ stream disconnected before completion` error scrolls past the
  40-line `recent_lines` window → state falls back to `unknown`.
- "stall when log mtime ≥ N seconds" (Issue 22 fix) misfires during
  long thinking phases and misses cases where the TUI keeps repainting
  but nothing real is happening (Issue 24).
- "wait for `state=prompt` + `IDLE>=N`" misses 6 hours of overnight
  productivity because Codex never quite hits `prompt` after a turn
  completes (Issue 25 — burned ~6h of unattended chain on
  2026-05-01 → 02).
- Pane focus events reset `IDLE` (Issue 25 quirk) — a human peeking at
  a tmux pane to check progress falsely re-arms the watcher.

Each of these is a heuristic patch on top of a fundamentally lossy
signal. We are reading text that was rendered for a human, not a
machine. The right answer is to read the machine signal.

## The discovery

Codex 0.128.0 ships an `app-server` subcommand (marked `[experimental]`
but functional and used in production by OpenAI's own
[`codex-plugin-cc`](https://github.com/openai/codex-plugin-cc)):

```
$ codex app-server --help
[experimental] Run the app server or related tooling

Usage: codex app-server [OPTIONS] [COMMAND]

Commands:
  proxy                 Proxy stdio bytes to the running app-server control socket
  generate-ts           [experimental] Generate TypeScript bindings for the app server protocol
  generate-json-schema  [experimental] Generate JSON Schema for the app server protocol

Options:
  --listen <URL>   Transport: stdio:// (default), unix://, ws://IP:PORT, off
```

`codex-plugin-cc`'s entire approach to dispatching/monitoring Codex is
built on this RPC. Its client at
`plugins/codex/scripts/lib/app-server.mjs` is ~350 lines of
straightforward JSON-RPC over stdio. It receives `turn/completed`,
`turn/started`, `item/completed`, `error` notifications natively
(`codex.mjs:499–546`). **No pane scraping anywhere in the codebase.**

## Protocol summary (verified locally)

Wire format: **JSON-RPC 2.0, one message per line over stdio** (or
unix socket / WebSocket). Initialization handshake mirrors LSP/MCP.

**Request methods** (from `app-server-protocol.d.ts:57–66`):

```
initialize           — handshake; returns server capabilities
thread/start         — start a new conversation (returns threadId)
thread/resume        — resume an existing thread (native session resume)
thread/name/set
thread/list
review/start
turn/start           — submit user input; returns turnId
turn/interrupt       — cancel a running turn (replaces ctrl-C)
```

**Server notifications** (verified by generating
`/tmp/codex-schema/ServerNotification.json` via
`codex app-server generate-json-schema`):

```
error                       — structured error info; replaces our regex
                              on "■ stream disconnected"
thread/started
thread/status/changed
thread/archived | unarchived
turn/started
turn/completed              — THE killer signal; carries turn.status
                              and full turn metadata
item/started
item/completed              — granular tool-call completion
item/agentMessage/delta     — streaming agent text (opt-outable)
item/reasoning/*Delta       — streaming reasoning (opt-outable)
account/*                   — auth/usage/rate-limit notifications
```

The `optOutNotificationMethods` capability (set during `initialize`)
lets us suppress the streaming deltas we don't need — a noise-control
knob we currently don't have.

**Auth**: same as `codex` CLI. Uses local `codex login` state. Nothing
new to configure.

**Concurrency**: each `harnex run` invocation spawns its own
`codex app-server` subprocess. Multiple sessions = multiple
subprocesses, no shared state. (Optional future optimization: adopt
codex-plugin-cc's broker pattern to multiplex many sessions through
one app-server, but not needed for v1.)

## Proposal

Add a new adapter `lib/harnex/adapters/codex_appserver.rb` that speaks
JSON-RPC over stdio to a spawned `codex app-server`. Wire it into
`lib/harnex/runtime/session.rb` as the default transport when
`agent == "codex"`. Keep the existing PTY adapter for `claude` and
`generic` — those CLIs don't have an app-server equivalent and the
PTY transport is correct for them.

Backward compatibility on the user-facing surface:

- `harnex run codex` continues to work; only the transport changes
- `harnex send` becomes `turn/start` under the hood
- `harnex stop` becomes `thread/archive` or process-kill
- `harnex status --json` adds first-class `model`, `effort`, `last_completed_at` fields populated from notifications
- `harnex events --id` JSONL stream now sources from app-server notifications instead of pane-derived events; schema gets richer (the existing `started/exited/usage/git/summary` event types stay, and `task_complete` / `disconnected` arrive natively)
- `harnex wait --id <ID> --until task_complete` becomes a real, supported predicate (Issue 25 spec lands by construction)

### Adapter sketch (Ruby pseudocode)

```ruby
class CodexAppServerAdapter < Base
  def start(cwd:, env: {}, model: nil, effort: nil)
    @proc = IO.popen([env, "codex", "app-server"], "r+")
    @reader = Thread.new { read_loop }
    request("initialize", clientInfo: client_info, capabilities: {
      experimentalApi: false,
      optOutNotificationMethods: %w[
        item/agentMessage/delta
        item/reasoning/summaryTextDelta
        item/reasoning/summaryPartAdded
        item/reasoning/textDelta
      ]
    })
    notify("initialized", {})
  end

  def dispatch(prompt:, model: nil, effort: nil)
    cfg = {}
    cfg[:model] = model if model
    cfg[:reasoningEffort] = effort if effort
    @thread = request("thread/start", configuration: cfg)
    @turn = request("turn/start",
                    threadId: @thread["threadId"],
                    input: { content: prompt })
    @turn["turnId"]
  end

  def on_completed(&block); @handlers["turn/completed"]   = block; end
  def on_error(&block);     @handlers["error"]            = block; end
  def on_item_done(&block); @handlers["item/completed"]   = block; end

  def interrupt; request("turn/interrupt", turnId: @turn["turnId"]); end
  def resume(thread_id); request("thread/resume", threadId: thread_id); end

  private

  def read_loop
    while (line = @proc.gets)
      msg = JSON.parse(line)
      if msg["method"] && !msg.key?("id")
        @handlers[msg["method"]]&.call(msg["params"])
      elsif msg["id"]
        @pending.delete(msg["id"])&.call(msg)
      end
    end
  end
end
```

Real implementation: ~150–250 LOC for the adapter + JSON-RPC plumbing
+ tests using mocked stdio fixtures.

## What this closes by construction

| Issue | Closed how |
|-------|------------|
| `22` (Codex side) | `--watch --stall-after --max-resumes` not needed — we get `turn/completed` natively. PTY adapter retains the feature for `claude`/`generic`. |
| `24` (disconnect detection) | `error` notifications from app-server replace regex matching on pane text. No more "scrolled past the 40-line window." |
| `25` (task-complete signal) | `turn/completed` is the structured task-complete signal. `harnex wait --until task_complete` becomes a one-liner. |

## Acceptance criteria

- New `lib/harnex/adapters/codex_appserver.rb` with adapter contract
  matching `lib/harnex/adapters/base.rb`
- `lib/harnex/runtime/session.rb` selects the new adapter when
  `agent == "codex"` (with a `--legacy-pty` flag for emergency
  fallback during migration)
- `harnex events --id <ID>` emits `turn_completed`, `error`,
  `item_completed` events sourced from notifications
- `harnex wait --id <ID> --until task_complete` blocks until the
  notification arrives
- `harnex status --json` includes `model`, `effort`,
  `last_completed_at`, `auto_disconnects` fields
- Tests: spawn a real `codex app-server` against a fixture prompt
  ("Write a one-line poem about clouds. Then stop."), assert
  `turn/completed` arrives and `wait --until task_complete` returns
  within 30s
- Integration test: induce an error notification (interrupt mid-turn);
  assert `error` event flows through `harnex events`
- Documentation: replace `lib/harnex/adapters/codex.rb`'s pane-scraping
  description in TECHNICAL.md with the JSON-RPC contract; add
  `docs/codex-appserver.md`
- Issues 22 (Codex-side note), 24, 25 marked superseded with reference
  back here

## Risks & mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| `codex app-server` is `[experimental]` — protocol may change | Medium | Pin a minimum codex version (≥0.128.0). codex-plugin-cc is OpenAI's own product, so the surface is being kept stable for them. CI runs `generate-json-schema` and diffs against a checked-in baseline; bump = explicit gate. |
| Loss of human-readable tmux pane for live debugging | Low | `harnex events --id X --follow` streams notifications; render a status view from those. Separately, `codex resume <session-id>` pops a human into any thread interactively. |
| Codex version drift on consumer machines (need ≥0.128) | Low | `harnex doctor` preflight; clear error on too-old binary. |
| Adapter base contract may need extending for richer event types | Low | The base contract is small (~5 methods). Extending it for both adapters is one PR. |
| Auth flow under app-server differs from interactive | Low (verified) | Uses same `codex login` state. No new credentials, no new env vars. |
| Concurrency edge cases (e.g. two harnex consumers calling app-server in same repo) | Low | v1: spawn-per-session. If contention emerges, lift codex-plugin-cc's broker pattern in a follow-up. |

## Tier & estimate

- **Tier**: A
- **Why A, not B**: novel transport, touches `runtime/session.rb` (the
  PTY state machine), introduces a new adapter base interaction. Not
  pattern-extension; architectural.
- **Phases**: plan → plan-review → fix → test-suite (TDD) → impl → code-review → fix
- **Estimated wall-clock**: ~6–8h of Codex time across the chain
- **Plan count**: 1 (single coherent plan; the adapter is the
  deliverable)

## Out of scope (separate issues if/when needed)

- Broker / multiplexing pattern (lift from codex-plugin-cc later)
- WebSocket transport (`--listen ws://`) — stdio is enough for v1
- Re-platforming `claude` adapter (no equivalent app-server in Claude
  Code CLI; PTY remains correct)
- Generic-adapter notifications (no app-server contract; pane
  remains the only signal)
- Repackaging harnex as a Claude Code plugin (separate Lane Plugin
  in holm Issue 271)

## Why now

The substrate audit on 2026-05-06 (holm Issue 271) confirmed:

1. We've been fighting the wrong battle for six weeks. Issues 22 / 24 /
   25 are all symptoms of one architectural mistake (PTY transport for
   a CLI that exposes a clean RPC).
2. The RPC is already shipped, locally available, and used in
   production by OpenAI's own plugin.
3. The cost of switching is bounded (~6–8h Codex). The cost of not
   switching is recurring: every Azure stream cut, every overnight
   chain, every "force resume" we send manually.

## Notes for the plan-write phase

- Read `~/Projects/outside_projects/codex-plugin-cc/plugins/codex/scripts/lib/app-server.mjs` (~350 lines) and
  `app-server-protocol.d.ts` for the canonical client shape — they are
  the reference implementation
- Generate the JSON schema fresh: `codex app-server generate-json-schema --out /tmp/codex-schema-latest`
- Compare against the v0.128.0 schema baseline (commit a copy under `test/fixtures/`)
- The TS bindings (`codex app-server generate-ts --out <DIR>`) name every notification and request type — useful as a Ruby type-mapping reference
