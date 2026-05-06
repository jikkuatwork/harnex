# Codex `app-server` adapter

harnex 0.6.0 talks to Codex over JSON-RPC 2.0 instead of scraping a
PTY pane. The adapter spawns `codex app-server` as a subprocess,
exchanges newline-delimited JSON-RPC messages on stdin/stdout, and
fans server notifications into the harnex events log.

## Transport

- Subprocess: `codex app-server` (CLI ≥ 0.128.0 — verify with
  `harnex doctor`).
- Wire format: one JSON object per line.
- Encoding: UTF-8.
- One `Adapter#transport` value: `:stdio_jsonrpc`.

## Handshake

Mirrors `codex-plugin-cc/plugins/codex/scripts/lib/app-server.mjs`.

```ruby
client.request("initialize", {
  clientInfo: { title: "harnex", name: "harnex", version: Harnex::VERSION },
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
client.notify("initialized", {})
```

After the handshake the client is ready to issue `thread/start` and
`turn/start` requests.

## Notification → event mapping

| Server notification         | harnex event       | Notes |
|-----------------------------|--------------------|-------|
| `thread/started`            | (metadata)         | Stashes `threadId` |
| `turn/started`              | `turn_started`     | Carries `turnId` |
| `turn/completed`            | `task_complete`    | Carries `turnId`, `status`, `tokenUsage` |
| `item/started`              | (silent)           | Streaming deltas opted out |
| `item/completed`            | `item_completed` + synthesized transcript | See "tmux/STDOUT" below |
| `error`                     | `disconnected`     | Increments `auto_disconnects` |
| `thread/status/changed`     | (state only)       | Drives state machine |
| `thread/tokenUsage/updated` | (status field)     | Surfaced via `harnex status --json` |
| `thread/compacted`          | `compaction`       | Increments `compactions` counter |
| `account/rateLimits/updated`| (silent, status)   | Visible in `status --json` |

### How disconnects are detected

Disconnects are detected from (a) JSON-RPC error responses keyed by
request `id` (e.g. `turn/start` rejected by the server), (b)
subprocess exit / EOF on stdout, and (c) parse errors when the
server emits a malformed line. The schema-defined `error`
notification is also wired to the same disconnect path.

In all cases `auto_disconnects` ticks and the session emits a
`disconnected` event. There is no need for the screen-text regex
that the legacy adapter relied on.

## tmux / STDOUT — synthesized transcript

Without a PTY, `harnex run codex --tmux` and `harnex pane --id …`
would otherwise see an empty pane. The JSON-RPC path renders a
synthesized transcript built from `item/completed` notifications:

- `agent_message` items render their text payload
- `tool_call` items render as `tool: <name> <one-line summary>`

The synthesized transcript is written to BOTH the output log AND
STDOUT, so:

- `harnex run codex` (foreground) — user sees the transcript live
- `harnex run codex --tmux` — the tmux window shows the transcript
- `harnex pane --id <session>` — captures the synthesized text
- `harnex logs --id <session>` — replays the same transcript

For interactive debugging where the original Codex TUI is wanted,
`codex resume <thread-id>` opens the same thread in a real Codex
CLI.

## `harnex wait --until task_complete`

Block until a Codex turn completes:

```
harnex wait --id cx-i-242 --until task_complete --timeout 300
```

The waiter tails the events JSONL — not the API socket — so it
keeps working across restarts and is adapter-agnostic.

## `harnex doctor`

Verifies the Codex CLI is installed and at version ≥ 0.128.0. JSON
output, exit 0 if healthy.

```
$ harnex doctor
{"ok":true,"checks":[{"name":"codex","required":">= 0.128.0","ok":true,"found":"0.128.0"}]}
```

## Long-term fallback: `--legacy-pty`

The pre-0.6.0 PTY adapter remains available as a long-term supported
fallback:

```
harnex run codex --legacy-pty
```

It's the right tool when you want the full Codex TUI live in tmux —
status bars, tool diffs, ANSI panels — that the headless `app-server`
backend doesn't render. JSON-RPC remains the default and is recommended
for autonomous worker dispatches; legacy-pty is for interactive/TUI use.

## Troubleshooting

- **`task_complete` never fires.** Almost always a Codex version
  issue. Run `harnex doctor`. If Codex < 0.128.0, upgrade.
- **Empty tmux pane.** Codex hasn't emitted any `item/completed`
  yet — the agent is reasoning. The pane fills as soon as the
  first item completes.
- **`disconnected` immediately after dispatch.** Check
  `harnex events --id <session>` for the JSON-RPC error message;
  the most common cause is auth (`OPENAI_API_KEY`) or model
  unavailability.

## Schema fixtures

`test/fixtures/codex_appserver/schema/` holds hand-pruned subsets
of `ServerNotification` and `ClientRequest` for the methods harnex
issues / consumes. Regenerate via:

```
codex app-server generate-json-schema --out /tmp/codex-schema-X
```

then re-prune. The full bundle is ~3 MB; the pruned subsets are
< 50 KB and serve as a compact reference for what's actually wired
through the adapter.
