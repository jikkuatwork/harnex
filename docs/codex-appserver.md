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
| `turn/completed`            | `task_complete` or `task_failed` | Failed/interrupted statuses emit `task_failed` with the Codex error. A completed `--context` turn emits `task_complete` only with structured command/tool activity or a Git delta; otherwise it emits typed `completed_no_activity`. Harnex writes the observed-state receipt before the successful event. |
| `item/started`              | (silent)           | Streaming deltas opted out |
| `item/completed`            | `item_completed` + synthesized transcript | See "tmux/STDOUT" below |
| `error`                     | `error`            | Turn-level Codex error notification; preserves nested `error.message` and does not count as a transport disconnect. |
| `thread/status/changed`     | (state only)       | Drives state machine |
| `thread/tokenUsage/updated` | (status field)     | Surfaced via `harnex status --json` |
| `thread/compacted`          | `compaction`       | Increments `compactions` counter |
| `account/rateLimits/updated`| (silent, status)   | Visible in `status --json` |

### How disconnects are detected

Disconnects are detected from subprocess exit / EOF on stdout and parse errors
when the server emits a malformed line. Request-level JSON-RPC error responses
reject only the in-flight request; they do not by themselves imply that the
transport disconnected. Schema-defined `error` notifications are turn-level
Codex errors and feed `last_error` / `task_failed` rather than the disconnect
counter.

Unexpected transport loss emits `disconnected` and increments
`auto_disconnects`. Normal auto-stop teardown after `task_complete` /
`task_failed` is treated as a clean structured close. There is no need for the
screen-text regex that the legacy adapter relied on.

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

## `harnex wait --until done` / `task_complete` / `task_failed`

For unattended monitors, block until Codex work completes, fails, or the session exits:

```
harnex wait --id cx-i-242 --until done --timeout 300
```

When you need the exact successful structured turn event, wait for `task_complete`:

```
harnex wait --id cx-i-242 --until task_complete --timeout 300
```

`--until done` returns non-zero when it sees `task_failed` or failed terminal
telemetry. This includes acknowledgment-only autonomous `--context` turns
(`outcome_class=completed_no_activity`) and the rare receipt-write failure
(`report_invalid`). Harnex classifies completion from app-server item counters
and Git state; it does not inspect final-answer prose or trust worker claims.
The task-complete/task-failed waiters
tail the events JSONL — not the API socket — so they keep working across
restarts and are adapter-agnostic.

Every blind dispatch receives a harness-authored receipt. No worker report is
required: Harnex captures command exits, Git state, completion, and usage, then
writes `HARNEX_ARTIFACT_REPORT_PATH` before emitting `task_complete`. Use
`--artifact-report PATH` only to choose a fixed destination; otherwise the
status/end row points to the default state-directory path. Review workers may
write advisory summary/verdict/P1-P3 counts to `HARNEX_ARTIFACT_CLAIMS_PATH`.
Claims and report-shaped `agentMessage` text cannot satisfy the activity gate.
Consumers can run `harnex artifact-report validate PATH --final` afterward.

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

- **`task_complete` never fires.** Check `harnex events --id <session>` first:
  failed Codex turns emit `task_failed` with the provider/model error. If there
  is neither `task_complete` nor `task_failed`, run `harnex doctor`; Codex <
  0.128.0 is unsupported.
- **Empty tmux pane.** Codex hasn't emitted any `item/completed`
  yet — the agent is reasoning. The pane fills as soon as the
  first item completes.
- **`task_failed` immediately after dispatch.** Check
  `harnex events --id <session>`. Provider/model failures retain their Codex
  error message. `completed_no_activity` means the turn ended with no
  command/tool or Git activity. `report_invalid` now primarily identifies a
  harness receipt-write failure; old rows may still contain the legacy
  `report_missing` / `report_rejected` classes. Common provider failures
  include auth environment variables (for example `OPENAI_API_KEY` /
  `AZURE_OPENAI_API_KEY`) and model unavailability.

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
