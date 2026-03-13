# Harnex

Harnex is a small PTY harness for interactive terminal agents.

It wraps a normal CLI session, keeps the terminal experience intact, and opens a
local control plane so another process can:

- discover the active session for the current repo
- inspect its status
- inject the next message as if it were typed
- press Enter to submit that message

Harnex currently ships with adapter-backed support for:

- `codex`
- `claude`

Each adapter owns its launch command, default flags, submit behavior, and UI
state detection. That keeps the transport generic while making room for
CLI-specific handling over time.

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

Start Codex in the current repo:

```bash
harnex run codex
```

Start Claude with a label:

```bash
harnex run claude --label review
```

Start Codex with a watched file hook:

```bash
harnex run codex --label hello --watch ./tmp/tick.jsonl
```

Forward extra args to the adapter command:

```bash
harnex run codex -- --cd /path/to/repo
```

List live sessions in the current repo:

```bash
harnex status
```

Send text and submit it when there is only one live session:

```bash
harnex send --message "Summarize current progress."
```

Send to a specific labeled session:

```bash
harnex send --label review --message "Summarize current progress."
```

If a workflow label has both Codex and Claude attached, add `--cli`:

```bash
harnex send --label review --cli codex --message "Summarize current progress."
```

Press Enter without sending new text:

```bash
harnex send --label review --enter
```

Type into the prompt without submitting:

```bash
harnex send --label review --no-submit --message "draft only"
```

Inspect the active session:

```bash
harnex send --label review --status
```

Debug repo/session resolution:

```bash
harnex send --label review --debug --message "status?"
```

## Command Model

Harnex ships as one command with three subcommands:

- `harnex run` starts the wrapped interactive session and local API
- `harnex send` resolves the target session and sends control input to it
- `harnex status` lists live sessions in a table

The bare `harnex` form is an alias for `harnex run codex`.

`harnex run` accepts a built-in adapter name:

- `codex`
- `claude`

Examples:

```bash
harnex run codex
harnex run claude
harnex run codex --label hello
harnex run codex --label hello --watch ./tmp/tick.jsonl
harnex run codex -- --cd /path/to/repo
```

`harnex send` is semantic, not just raw typing. It asks the live session's
adapter how to submit input. By default it submits after typing. Use
`--no-submit` to only type, `--enter` to send only Enter, or `--force` to
bypass adapter readiness checks.

Wrapper options like `--label` may appear before or after the adapter name:

```bash
harnex run --label hello codex
harnex run codex --label hello
```

## Adapters

Current built-in adapters:

- `codex` launches `codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen`
- `claude` launches `claude --dangerously-skip-permissions`

The Codex adapter forces inline mode with `--no-alt-screen` so recent terminal
output remains easier to inspect and parse.

The Claude adapter currently detects the workspace trust prompt and marks the
session as not ready for message typing until that prompt is cleared.

Adapter state shows up in `harnex send --status` and the HTTP status payload.

## Session Resolution

Each session is scoped by:

- repo root
- label
- CLI

If you do not pass `--label`, Harnex uses the adapter name as the label. That
means these two sessions can coexist without extra flags:

```bash
harnex run codex
harnex run claude
```

Session metadata is written to:

```text
~/.local/state/harnex/sessions/<repo-hash>--<label>--<cli>.json
```

That registry entry includes:

- repo root
- label
- CLI
- PID
- host and chosen port
- bearer token
- start time
- injection counters

This means multiple sessions can coexist safely:

```bash
harnex run codex --label main
harnex run claude --label monitor

harnex send --label main --message "Status?"
harnex send --label monitor --message "Summarize the queue."
```

You can also reuse one workflow label across both CLIs:

```bash
harnex run codex --label hello
harnex run claude --label hello

harnex send --label hello --cli codex --message "/tick"
harnex send --label hello --cli claude --message "/tick"
```

If exactly one live session matches the requested label, `harnex send --label`
does not need `--cli`. If both Codex and Claude are live under that label,
`harnex send --label hello` is ambiguous and will ask for `--cli`.

If exactly one live session exists in the current repo, `harnex send` can target
it without `--label`. If multiple sessions are live, `harnex send` will ask you
to choose with `--label` and `harnex status` will show the available targets.

## Two-Agent Relay

One useful pattern is to run both agents under one shared workflow label in
adjacent tmux panes, then let either agent call `harnex send` to talk to the
other one.

Start both:

```bash
harnex run codex --label hello
harnex run claude --label hello
```

Then, from inside the Codex pane:

```bash
harnex send --label hello --cli claude --message "please review plan 34"
```

and from inside the Claude pane:

```bash
harnex send --label hello --cli codex --message "review passed; please apply the fixes"
```

When `harnex send` runs from inside another Harnex-managed session and targets a
different live session, Harnex automatically wraps the message with a relay
header and a newline before the body:

```text
[harnex relay from=codex label=hello at=2026-03-14T00:29:18+04:00]
please review plan 34
```

That keeps short peer-to-peer exchanges in-band and reviewable without making
them look like raw user input. Use `--no-relay` to disable the automatic
wrapper, or `--relay` to force it when the send originates from another
Harnex-managed session.

## Live Discussion Workflow

One practical use of Harnex is a visible discussion loop between you, Codex,
and Claude under one shared label.

Start both sessions:

```bash
harnex run codex --label discuss
harnex run claude --label discuss
```

Seed a topic in one pane from your shell:

```bash
harnex send --label discuss --cli codex --message "Topic: should Harnex ship screen_tail before SSE?"
```

Then ask the other side to answer through Harnex instead of only replying in
its own pane:

```bash
harnex send --label discuss --cli claude --message "Please reply back to Codex through harnex with your view, then wait for follow-up."
```

From there, you can pause at any point and type directly into either pane. If
you want one side to answer a question and relay that answer back to the other
side, just ask it explicitly:

```bash
harnex send --label discuss --cli codex --message "Please answer the user's question and send the answer back to Claude through harnex."
harnex send --label discuss --cli claude --message "Please answer the user's question and send the answer back to Codex through harnex."
```

The important property is that the sessions stay human-visible and
human-interruptible. Harnex handles discovery and message injection, but you
can still steer either conversation manually at any time.

## File Hooks

`harnex run --watch PATH` adds one dumb file-change hook to that session.

When `PATH` changes, Harnex waits for 1 second of quiet time and then sends:

```text
file-change-hook: read ./tmp/tick.jsonl
```

Harnex does not parse the file, track offsets, or interpret its contents. It
just tells the running CLI to reread the watched path. The repository workflow
owns everything after that.

Example:

```bash
harnex run codex --label hello --watch ./tmp/tick.jsonl
harnex run claude --label hello --watch ./tmp/tick.jsonl
```

That shared-file pattern works well when the repo wants one append-only log that
both agents reread on change.

Notes:

- relative watch paths are resolved from the session repo root
- Harnex creates the watched file's parent directory if needed
- the watched file itself does not need to exist at startup
- rapid bursts of file changes are collapsed into one hook message after 1 second
- the current implementation uses Linux inotify
- `harnex send --status` includes the active watch path and debounce value

If you want per-agent inbox files instead, that works too:

```bash
harnex run codex --label hello --watch ./tmp/inbox.codex
harnex run claude --label hello --watch ./tmp/inbox.claude
```

## Port Selection

Harnex picks a deterministic starting port from the repo root, label, and CLI,
then walks forward until it finds a free port.

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
  "cli": "codex",
  "label": "main",
  "pid": 12345,
  "host": "127.0.0.1",
  "port": 43123,
  "command": ["codex", "--dangerously-bypass-approvals-and-sandbox", "--no-alt-screen"],
  "started_at": "2026-03-13T20:45:00Z",
  "last_injected_at": null,
  "injected_count": 0,
  "input_state": {
    "state": "prompt",
    "input_ready": true
  }
}
```

### `harnex status`

Prints a repo-scoped table of live sessions, including the label, adapter, age,
last injection time, and current input state.

Example:

```text
LABEL   CLI     PID      PORT   AGE      LAST     STATE
------  ------  -------  -----  -------  -------  -------
claude  claude  1919632  46769  8s ago   never    unknown
codex   codex   1919287  43371  36s ago  29s ago  prompt
```

### `POST /send`

Send JSON:

```json
{"text":"Summarize current progress.","submit":true,"enter_only":false,"force":false}
```

or use the legacy raw text/newline form.

The send endpoint now routes through the active adapter. That adapter can:

- transform submit behavior for the target CLI
- report whether the UI looks ready for prompt input
- refuse obviously unsafe sends unless `force` is set

For example, the Claude adapter can block normal message typing while the
workspace trust prompt is on screen, but `harnex send --enter` still works for
that prompt.

In most cases, `harnex send` is the better interface because it handles submit
behavior for you.

## Shell Quoting

`"hello\n"` is usually the literal characters `\` and `n`, not a newline.

If you need a real newline inside the injected text, use shell syntax that
produces one, for example:

```bash
harnex send --label review --message $'line one\nline two'
```

## Environment

Primary environment variables:

- `HARNEX_LABEL` - override the automatic label default
- `HARNEX_HOST` - bind host
- `HARNEX_PORT` - force a specific port
- `HARNEX_BASE_PORT` - base automatic port
- `HARNEX_PORT_SPAN` - automatic port range size
- `HARNEX_STATE_DIR` - state directory override
- `HARNEX_SEND_WAIT` - sender retry window in seconds
- `HARNEX_TRACE=1` - print backtraces on CLI errors

Legacy compatibility aliases are still accepted for now:

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
- Adapter readiness is heuristic. `input_state` is useful, but not perfect.
- `harnex send` may refuse to type when an adapter recognizes a non-prompt
  state. Use `--force` to bypass that check.
- Claude may start with a workspace trust prompt, which usually needs
  `harnex send --enter` before normal message injection.
- `harnex status` shows the latest reachable state, but it still depends on
  adapter heuristics and local HTTP reachability.
- `harnex send --debug` shows repo resolution, registry lookup, and target URL.

## Status

Harnex is usable now, but it is still early. The current shape is:

- solid repo-aware session lookup
- adapter-backed Codex and Claude launch profiles
- labeled multi-session routing
- shared workflow labels across Codex and Claude
- optional-label single-session targeting
- repo-scoped live session table via `harnex status`
- typed message injection and submit control
- simple local HTTP control surface

Likely next steps are event streaming, watchers, and higher-level monitoring
primitives on top of the current PTY bridge.
