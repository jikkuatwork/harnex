---
status: closed
priority: P1
---

# Issue 44 — First-class Pi RPC adapter

**Status**: closed (shipped in 0.7.4; compatibility hardened after Pi 0.84 audit)
**Priority**: P1
**Filed**: 2026-05-23
**Tier**: B (plan -> impl -> verification)
**Sister**: related to #27 (Codex app-server adapter), #42 (structured orchestrator recovery), #43 (throughput-first telemetry v2), and #46 (restore cost telemetry).

## Problem

The operator has moved most orchestration work to Pi (`pi.dev` / `@earendil-works/pi-coding-agent`). harnex can launch unknown CLIs through the generic PTY adapter, but that path only sees terminal text. It does not expose Pi's structured completion, token/cost stats, tool events, retry/compaction state, or durable session identity.

Pi ships a programmatic RPC mode that is a better fit for autonomous harnex dispatch:

```bash
pi --mode rpc
```

RPC mode uses strict LF-delimited JSONL over stdin/stdout. It is **not JSON-RPC 2.0** and should not be treated as Codex `app-server`, but it provides enough structured commands/events for first-class harnex support.

## Research findings

Validated locally against Pi `0.75.4` (`@earendil-works/pi-coding-agent`). Relevant docs inspected:

- `README.md` — Programmatic Usage section
- `docs/rpc.md` — RPC protocol
- `docs/sdk.md` — SDK and runtime APIs
- `docs/json.md` — event stream mode
- `docs/session-format.md` / `docs/sessions.md` — durable session JSONL format
- `docs/extensions.md` — RPC extension UI behavior and extension hooks
- `docs/settings.md`, `docs/providers.md`, `docs/models.md`, `docs/custom-provider.md`
- `examples/sdk/` and `examples/rpc-extension-ui.ts`

### Protocol shape

Commands are JSON objects on stdin, one per line. Responses and events are JSON objects on stdout, one per line. Clients must split only on `\n`.

Useful commands:

- `prompt` — send a user prompt; response means accepted/queued, not complete
- `steer` / `follow_up` — queue messages while the agent is busy
- `abort` — abort current operation
- `get_state` — model, thinking level, streaming/compacting state, session id/file, queue counts
- `get_session_stats` — messages, tool calls/results, tokens, cost, context usage
- `get_messages` / `get_last_assistant_text`
- `switch_session` / `new_session` / `fork` / `clone`
- `set_model`, `set_thinking_level`, `set_auto_retry`, `set_auto_compaction`

Useful events:

- `agent_start`, `agent_end`
- `turn_start`, `turn_end`
- `message_start`, `message_update`, `message_end`
- `tool_execution_start`, `tool_execution_update`, `tool_execution_end`
- `queue_update`
- `compaction_start`, `compaction_end`
- `auto_retry_start`, `auto_retry_end`
- `extension_error`
- `extension_ui_request`

Pi's durable resume primitive is the persisted **session JSONL file** (`sessionFile`), not a Codex-style `threadId`. Recovery should restart Pi with `--session <sessionFile>` or use `switch_session`, then send a bounded recovery prompt.

## Goal

Add an opt-in/new first-class harnex adapter for Pi RPC mode so harnex can run Pi workers with structured state, completion, telemetry, and stop behavior.

Initial target surface:

```bash
harnex run pi --id cx-i-pi --context "Implement ..."
harnex run pi --id cx-i-pi --context "Implement ..." -- --model anthropic/claude-sonnet-4-5 --thinking high
harnex run pi --id cx-i-pi --context "Implement ..." --auto-stop
```

Forwarded Pi CLI flags must go after `--`, because harnex rejects unknown wrapper flags before the separator.

## Proposed design

### Adapter

Add `Harnex::Adapters::Pi` for `pi --mode rpc`.

Open design point: either introduce a generic structured transport such as `:stdio_jsonl_rpc`, or keep a Pi-specific path beside the Codex app-server path. The important constraint is not to force Pi into Codex's JSON-RPC 2.0 client.

Base command should include:

```ruby
["pi", "--mode", "rpc"]
```

The adapter should preserve user-supplied Pi args, including model/session/tool flags.

### Context delivery

Do not pass harnex `--context` as a Pi positional message in RPC mode. Strip the harnex context marker from adapter args and deliver it as a `prompt` command after the RPC process is started.

### State mapping

- `agent_start` / `turn_start` => busy
- `agent_end` => remain busy; retries, compaction, or queued continuation may
  follow
- `agent_settled` + final assistant `stopReason=stop` => prompt / task complete
- terminal error/aborted/length or missing final outcome => task failed
- `compaction_*` => compaction telemetry
- `auto_retry_*` => retry telemetry, not final completion/failure
- process EOF / parse failure / transport death => disconnected/failure

### Output synthesis

Append human-readable output to harnex output logs from:

- `message_update.assistantMessageEvent.text_delta`
- `message_end` text blocks as a fallback
- `tool_execution_start/end` compact summaries
- `extension_ui_request` notifications/status widgets as compact log entries

### Extension UI handling

Pi extensions can block in RPC mode while waiting for `extension_ui_response`. harnex must handle this in MVP.

Recommended MVP behavior:

- auto-cancel dialog methods: `select`, `confirm`, `input`, `editor`
- log fire-and-forget methods: `notify`, `setStatus`, `setWidget`, `setTitle`, `set_editor_text`
- document that deterministic workers can run with `-- --no-extensions`

Later, harnex can expose extension UI requests over its own API for a human/orchestrator to answer.

### Telemetry

At session end, call `get_session_stats` when possible and map:

- `tokens.input` -> `actual.input_tokens`
- `tokens.output` -> `actual.output_tokens`
- `tokens.cacheRead` -> `actual.cached_tokens`
- `tokens.total` -> `actual.total_tokens`
- `toolCalls` -> `actual.tool_calls`
- `cost` -> restored `actual.cost_usd` (see #46)
- `sessionId` / `sessionFile` -> agent session identity metadata
- current model provider/model from `get_state.model` or assistant messages

Pi can use many providers, so `agent_provider` should be dynamic for this adapter rather than hard-coded to `openai`/`anthropic`.

### Stop behavior

For harnex stop / auto-stop:

1. if Pi is busy, send `abort`
2. close stdin or terminate the subprocess
3. persist final telemetry and classify clean task completion only after `agent_settled`

## Acceptance criteria

- `harnex run pi --context ... --auto-stop` starts `pi --mode rpc`, sends the context as a `prompt`, observes structured completion, and exits cleanly.
- `harnex send --id <pi-session> --message ...` sends a prompt when Pi is idle.
- Sending while busy without an explicit force/queue policy is rejected with a clear error.
- Pi `agent_settled` maps successful final outcomes to harnex `task_complete`
  and supports auto-stop; `agent_end` alone never completes work.
- Pi `get_session_stats` populates token counters, tool-call counters, dynamic model/provider, session identity, and restored cost telemetry when available.
- Extension UI requests do not hang the worker; dialog requests are auto-cancelled and logged.
- RPC parse/transport disconnects emit failure/disconnection telemetry instead of hanging.
- Tests cover the adapter with a stub Pi RPC subprocess: prompt acceptance, text deltas, tool events, stats collection, extension UI auto-cancel, abort/stop, and EOF/disconnect.
- README / agent guide docs show Pi RPC usage and the `--` child-flag pattern.

## Resolution

Shipped in Harnex 0.7.4 (`08f5a9e`) with release evidence in
`koder/releases/0.7.4.md`.

A 2026-08-14 audit against installed Pi 0.84.1 found and hardened later
protocol drift:

- Harnex now requires Pi >= 0.80.4 and completes only on `agent_settled`, not
  the lower-level `agent_end` that can precede retries, compaction, or queued
  continuations.
- Pi 0.84's delta-only `message_update` shape is correlated through
  `message_start` / authoritative `message_end` without duplicate output.
- final assistant `error`, `aborted`, `length`, missing, and unknown stop reasons
  fail closed;
- Harnex `--model` / `--effort` use supported Pi startup controls verified by
  RPC `get_state`, rather than unsupported fields on `prompt` or persistent RPC
  setters, and forced busy sends use Pi steering;
- request waits, stderr capture, and subprocess status collection are bounded
  and deterministic;
- `harnex doctor --adapter pi` reports the compatibility gate.

Current transport behavior and project-trust requirements are documented in
`docs/pi-rpc.md`.

## Out of scope

- Visible Pi TUI / PTY support. Tracked separately in #45.
- Building a Node SDK bridge. Ruby should integrate via `pi --mode rpc` first.
- Full interactive extension UI mediation through harnex API. MVP auto-cancels dialogs.
- Cross-provider canonical cost normalization beyond restoring provider-reported Pi cost fields (#46).

## Triage

- **Tier**: B
- **Plan count**: 1
- **Estimated sessions**: 1–2
- **Estimated wall-clock**: ~3–5h

## Notes

This should become the preferred autonomous adapter for Pi. PTY remains a separate visible-TUI task because stable prompt markers are better solved with a Pi extension rather than brittle screen scraping.
