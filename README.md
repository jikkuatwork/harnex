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

Start Claude with an ID:

```bash
harnex run claude --id review
```

Start Codex with a watched file hook:

```bash
harnex run codex --id hello --watch ./tmp/tick.jsonl
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

Send to a specific session:

```bash
harnex send --id review --message "Summarize current progress."
```

Press Enter without sending new text:

```bash
harnex send --id review --enter
```

Type into the prompt without submitting:

```bash
harnex send --id review --no-submit --message "draft only"
```

Inspect the active session:

```bash
harnex send --id review --status
```

Debug repo/session resolution:

```bash
harnex send --id review --debug --message "status?"
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
harnex run codex --id hello
harnex run codex --id hello --watch ./tmp/tick.jsonl
harnex run codex -- --cd /path/to/repo
```

`harnex send` is semantic, not just raw typing. It asks the live session's
adapter how to submit input. By default it submits after typing. Use
`--no-submit` to only type, `--enter` to send only Enter, or `--force` to
bypass adapter readiness checks.

Wrapper options like `--id` may appear before or after the adapter name:

```bash
harnex run --id hello codex
harnex run codex --id hello
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

Each session is uniquely addressed by its **ID** within a repo. If you do not
pass `--id`, Harnex uses the adapter name as the default ID. That means these
two sessions can coexist without extra flags:

```bash
harnex run codex       # id: codex
harnex run claude      # id: claude
```

Session metadata is written to:

```text
~/.local/state/harnex/sessions/<repo-hash>--<id>.json
```

That registry entry includes:

- repo root
- ID
- CLI
- PID
- host and chosen port
- bearer token
- start time
- injection counters

Multiple sessions coexist naturally with different IDs:

```bash
harnex run codex --id impl-1
harnex run codex --id impl-2
harnex run codex --id impl-3
harnex run claude --id reviewer

harnex send --id impl-1 --message "implement plan 150"
harnex send --id impl-2 --message "implement plan 151"
harnex send --id reviewer --message "review worktree changes"
```

If exactly one live session exists in the current repo, `harnex send` can target
it without `--id`. If multiple sessions are live, `harnex send` will ask you
to choose with `--id` and `harnex status` will show the available targets.

## Two-Agent Relay

One useful pattern is to run both agents with known IDs in adjacent tmux panes,
then let either agent call `harnex send` to talk to the other one.

Start both:

```bash
harnex run codex --id worker
harnex run claude --id reviewer
```

Then, from inside the Codex pane:

```bash
harnex send --id reviewer --message "please review plan 34"
```

and from inside the Claude pane:

```bash
harnex send --id worker --message "review passed; please apply the fixes"
```

When `harnex send` runs from inside another Harnex-managed session and targets a
different live session, Harnex automatically wraps the message with a relay
header and a newline before the body:

```text
[harnex relay from=codex id=worker at=2026-03-14T00:29:18+04:00]
please review plan 34
```

That keeps short peer-to-peer exchanges in-band and reviewable without making
them look like raw user input. Use `--no-relay` to disable the automatic
wrapper, or `--relay` to force it when the send originates from another
Harnex-managed session.

## Message Queue

When a peer agent is busy (e.g. Codex running a long task), messages are
automatically queued in the target session's inbox and delivered when the agent
returns to a prompt.

- **Immediate delivery** (HTTP 200): agent is at a prompt and queue is empty
- **Queued delivery** (HTTP 202): agent is busy; message queued for auto-delivery
- **Force delivery**: `--force` bypasses the queue and injects immediately

The sender automatically polls for delivery status unless `--async` is used:

```bash
# Wait for delivery (default, up to --wait seconds)
harnex send --id worker --message "implement plan 150"

# Return immediately with message_id
harnex send --id worker --async --message "implement plan 150"
```

Session status includes inbox stats:

```bash
harnex send --id worker --status
# → { ..., "agent_state": "busy", "inbox": { "pending": 2, "delivered_total": 5 } }
```

## Detached Sessions

`--detach` starts a session in the background and returns immediately with
JSON containing the pid, port, and mode.

### Headless

```bash
harnex run codex --id impl-1 --detach -- --cd /path/to/worktree
```

The session runs as a background process. Output goes to
`~/.local/state/harnex/logs/<id>.log`. There is no terminal attached — all
interaction happens through `harnex send` and `harnex wait`.

### tmux

```bash
harnex run codex --id impl-1 --tmux -- --cd /path/to/worktree
harnex run codex --id impl-1 --tmux cx-p1 -- --cd /path/to/worktree
```

`--tmux` implies `--detach`. The session runs inside a new tmux window. You can
switch to that window to watch it live, or leave it in the background.

The optional argument after `--tmux` sets the window title. Keep names terse so
they fit in narrow tmux tab bars — e.g. `cx-p3` for "codex plan 3", `cl-r3` for
"claude review 3". If omitted, the session ID is used as the window name.

If you are already inside a tmux session, the window is added there. Otherwise
a new `harnex` tmux session is created.

### Waiting for completion

```bash
harnex wait --id impl-1
harnex wait --id impl-1 --timeout 300
```

`harnex wait` blocks until the session process exits. Returns JSON with exit
code and timing. Exit code 124 on timeout.

When a session exits, it writes its final status to
`~/.local/state/harnex/exits/<id>.json` so `harnex wait` can report the result
even after the process is gone.

### Supervisor workflow

A supervisor session (e.g. Claude) can spawn workers, send them tasks, and
sequence through a plan queue:

```bash
# Implement phase — spawn worker in a tmux window
harnex run codex --id codex-plan-a --tmux cx-pa -- --cd ~/repo/wt-plan-a
harnex send --id codex-plan-a --message "implement plan A"
harnex wait --id codex-plan-a

# Review phase
harnex run claude --id review-a --tmux cl-ra
harnex send --id review-a --message "review changes in wt-plan-a"
harnex wait --id review-a

# Branch: fix loop or next plan based on exit code
```

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
harnex run codex --id hello --watch ./tmp/tick.jsonl
harnex run claude --id hello-review --watch ./tmp/tick.jsonl
```

Notes:

- relative watch paths are resolved from the session repo root
- Harnex creates the watched file's parent directory if needed
- the watched file itself does not need to exist at startup
- rapid bursts of file changes are collapsed into one hook message after 1 second
- the current implementation uses Linux inotify
- `harnex send --status` includes the active watch path and debounce value

## Port Selection

Harnex picks a deterministic starting port from the repo root and session ID,
then walks forward until it finds a free port.

Defaults:

- host: `127.0.0.1`
- base port: `43000`
- span: `4000`

This keeps ports stable enough to reason about, while still allowing multiple
repos and IDs to coexist.

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
  "id": "impl-1",
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
  },
  "agent_state": "prompt",
  "inbox": {
    "pending": 0,
    "delivered_total": 3
  }
}
```

### `harnex status`

Prints a repo-scoped table of live sessions:

```text
ID       CLI     PID      PORT   AGE      LAST     STATE
-------  ------  -------  -----  -------  -------  -------
impl-2   codex   1919632  46769  8s ago   never    unknown
impl-1   codex   1919287  43371  36s ago  29s ago  prompt
```

### `POST /send`

Send JSON:

```json
{"text":"Summarize current progress.","submit":true,"enter_only":false,"force":false}
```

Returns HTTP 200 with `"status":"delivered"` for immediate delivery, or HTTP 202
with `"status":"queued"` and a `message_id` when the agent is busy.

### `GET /messages/:id`

Poll delivery status of a queued message by its `message_id`.

## Shell Quoting

`"hello\n"` is usually the literal characters `\` and `n`, not a newline.

If you need a real newline inside the injected text, use shell syntax that
produces one, for example:

```bash
harnex send --id review --message $'line one\nline two'
```

## Environment

Primary environment variables:

- `HARNEX_ID` - override the automatic ID default
- `HARNEX_HOST` - bind host
- `HARNEX_PORT` - force a specific port
- `HARNEX_BASE_PORT` - base automatic port
- `HARNEX_PORT_SPAN` - automatic port range size
- `HARNEX_STATE_DIR` - state directory override
- `HARNEX_SEND_WAIT` - sender retry window in seconds (default: 30)
- `HARNEX_TRACE=1` - print backtraces on CLI errors

Legacy compatibility aliases are still accepted:

- `HARNEX_LABEL` (alias for `HARNEX_ID`)
- `CXW_HOST`
- `CXW_PORT`
- `CXW_BASE_PORT`
- `CXW_PORT_SPAN`
- `CXW_STATE_DIR`
- `CXW_SEND_WAIT`
- `CXW_TRACE`

## Caveats

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
- unique ID-based session addressing
- multiple instances of the same CLI with different IDs
- detached sessions with headless and tmux modes
- `harnex wait` for blocking on session completion
- message queue with automatic delivery when agents become ready
- repo-scoped live session table via `harnex status`
- typed message injection and submit control
- simple local HTTP control surface
