# Harnex

Harnex is a small PTY harness for interactive terminal agents.

It wraps a normal CLI session, keeps the terminal experience intact, and opens a
local control plane so another process can:

- discover the active session for the current repo
- inspect its status
- inject the next message as if it were typed
- press Enter to submit that message

The default wrapped command matches the existing `cx` alias behavior:

```bash
codex --dangerously-bypass-approvals-and-sandbox
```

You can override that and use Harnex with any interactive command.

## Why

Most agent CLIs are great when a human is driving them directly, but awkward to
monitor or steer from another process. Harnex keeps the human-facing terminal
session exactly where it is and adds a thin repo-scoped API beside it.

The goal is not orchestration. The goal is a stable harness:

- one interactive pane
- one repo-aware session registry
- one tiny local API
- zero UI changes to the wrapped tool

## Quick Start

Start a labeled session in any repo:

```bash
harnex --label main
```

Send text and submit it:

```bash
harnex-send --label main --message "Summarize current progress."
```

Press Enter without sending new text:

```bash
harnex-send --label main --enter
```

Type into the prompt without submitting:

```bash
harnex-send --label main --no-submit --message "draft only"
```

Inspect the active session:

```bash
harnex-send --label main --status
```

Debug repo/session resolution:

```bash
harnex-send --label main --debug --message "status?"
```

## Command Model

Harnex ships with two commands:

- `harnex` starts the wrapped interactive session and local API
- `harnex-send` resolves the target session and sends control input to it

By default, `harnex-send` appends a real Enter keystroke after the message so
the wrapped prompt submits like normal typing. Use `--no-submit` to only type,
or `--enter` to submit whatever is already in the input buffer.

## Session Resolution

Each session is scoped by:

- repo root
- label

Session metadata is written to:

```text
~/.local/state/harnex/sessions/<repo-hash>--<label>.json
```

That registry entry includes:

- repo root
- label
- PID
- host and chosen port
- bearer token
- start time
- injection counters

This means multiple sessions can coexist safely:

```bash
harnex --label main
harnex --label monitor

harnex-send --label main --message "Status?"
harnex-send --label monitor --message "Summarize the queue."
```

If multiple sessions use the same repo and the same label, the newest session
wins for that label.

## Port Selection

Harnex picks a deterministic starting port from the repo root and label, then
walks forward until it finds a free port.

Defaults:

- host: `127.0.0.1`
- base port: `43000`
- span: `4000`

This keeps ports stable enough to reason about, while still allowing multiple
repos and labels to coexist.

## HTTP API

All endpoints bind to loopback by default.

### `GET /status`

Returns session metadata:

```json
{
  "ok": true,
  "session_id": "abc123...",
  "repo_root": "/path/to/repo",
  "label": "main",
  "pid": 12345,
  "host": "127.0.0.1",
  "port": 43123,
  "command": ["codex", "--dangerously-bypass-approvals-and-sandbox"],
  "started_at": "2026-03-13T20:45:00Z",
  "last_injected_at": null,
  "injected_count": 0
}
```

### `POST /send`

Send JSON:

```json
{"text":"Summarize current progress.","newline":true}
```

or a raw text body.

The PTY write is literal. If the wrapped tool is in a prompt, editor, or modal
UI, Harnex writes exactly where keystrokes would land.

To simulate pressing Enter through raw HTTP, append `\r` to the text and set
`newline` to `false`:

```json
{"text":"hello\r","newline":false}
```

In most cases, `harnex-send` is the better interface because it handles submit
behavior for you.

## Shell Quoting

`"hello\n"` is usually the literal characters `\` and `n`, not a newline.

If you need a real newline inside the injected text, use shell syntax that
produces one, for example:

```bash
harnex-send --label main --message $'line one\nline two'
```

## Environment

Primary environment variables:

- `HARNEX_COMMAND` - override the wrapped command
- `HARNEX_LABEL` - default session label
- `HARNEX_HOST` - bind host
- `HARNEX_PORT` - force a specific port
- `HARNEX_BASE_PORT` - base automatic port
- `HARNEX_PORT_SPAN` - automatic port range size
- `HARNEX_STATE_DIR` - state directory override
- `HARNEX_SEND_WAIT` - sender retry window in seconds
- `HARNEX_TRACE=1` - print backtraces on CLI errors

Legacy compatibility aliases are still accepted for now:

- `CXW_COMMAND`
- `CXW_LABEL`
- `CXW_HOST`
- `CXW_PORT`
- `CXW_BASE_PORT`
- `CXW_PORT_SPAN`
- `CXW_STATE_DIR`
- `CXW_SEND_WAIT`
- `CXW_TRACE`

## Caveats

- Injection is immediate PTY write-through. There is no queueing layer yet.
- If the wrapped tool is mid-input, injected bytes join the current input
  buffer.
- If the wrapped tool is in a full-screen interface, behavior is raw typing,
  because that is exactly what Harnex does.
- `harnex-send --debug` shows repo resolution, registry lookup, and target URL.

## Status

Harnex is usable now, but it is still early. The current shape is:

- solid repo-aware session lookup
- labeled multi-session routing
- typed message injection and submit control
- simple local HTTP control surface

Likely next steps are event streaming, watchers, and higher-level monitoring
primitives on top of the current PTY bridge.
