# Harnex

A PTY harness that lets AI agents talk to each other.

Harnex wraps terminal agents (Claude Code, Codex) in a thin local control
plane. Each agent keeps its normal terminal — harnex just adds discovery,
messaging, and coordination on top.

```
  ┌──────────────────────────────────────────────────────┐
  │                    Your Terminal                      │
  │                                                      │
  │  ┌─────────────┐   harnex send   ┌─────────────┐    │
  │  │  Claude      │ ─────────────> │  Codex       │    │
  │  │  id=review   │ <───────────── │  id=worker   │    │
  │  │              │   relay msg     │              │    │
  │  └──────┬───────┘                └──────┬───────┘    │
  │         │                               │            │
  │    :45899/send                    :43123/send         │
  │    :45899/status                  :43123/status       │
  │                                                      │
  │  ~/.local/state/harnex/sessions/                      │
  │    ├── <repo>--review.json                           │
  │    └── <repo>--worker.json                           │
  └──────────────────────────────────────────────────────┘
```

Each session gets a local HTTP API, a repo-scoped registry entry, and an
inbox queue. That's it. No orchestration framework, no custom protocols.

## Install

```bash
git clone https://github.com/jikkujose/harnex.git
ln -s $(pwd)/harnex/bin/harnex ~/.local/bin/harnex
```

Requires Ruby 3.x. No gem dependencies.

## Quick Start

```bash
# Start a codex session
harnex run codex

# Start claude with an ID
harnex run claude --id review

# List live sessions
harnex status

# Send a message
harnex send --id review --message "Summarize current progress."
```

## How It Works

```
  You type:  harnex run codex --id worker

  harnex does:
    1. Spawn codex under a PTY (terminal stays normal)
    2. Pick a local port (deterministic from repo + id)
    3. Start HTTP API on 127.0.0.1:<port>
    4. Write session file to ~/.local/state/harnex/sessions/
    5. Monitor screen output for prompt detection

  Other processes can now:
    harnex send --id worker --message "do something"
    harnex send --id worker --status
    harnex wait --id worker
```

## Commands

### `harnex run [cli] [options] [-- cli-args...]`

Start a wrapped session.

```bash
harnex run codex                          # default
harnex run claude --id review             # named session
harnex run codex -- --cd /path/to/repo    # forward args
```

Options:

| Flag | Purpose |
|------|---------|
| `--id ID` | Session ID (default: cli name) |
| `--detach` | Background, no terminal |
| `--tmux [NAME]` | Background in tmux window |
| `--context TEXT` | Initial prompt (auto-includes session ID) |
| `--watch PATH` | File change hook |
| `--host HOST` | Bind address (default: 127.0.0.1) |
| `--port PORT` | Force specific port |

### `harnex send [options]`

Send a message to a running session.

```bash
harnex send --id worker --message "implement plan A"
harnex send --id worker --enter           # just press Enter
harnex send --id worker --no-submit       # type without Enter
harnex send --id worker --status          # inspect session
harnex send --id worker --force           # bypass queue
harnex send --id worker --async           # don't wait for delivery
```

### `harnex status`

```
ID       CLI     PID      PORT   AGE      LAST     STATE
-------  ------  -------  -----  -------  -------  ------
worker   codex   1919287  43371  36s ago  29s ago  prompt
review   claude  1919632  46769  8s ago   never    busy
```

### `harnex wait --id ID`

Block until a session exits. Returns JSON with exit code.

```bash
harnex wait --id worker              # wait forever
harnex wait --id worker --timeout 300  # 5 min timeout
```

## Agent-to-Agent Messaging

When one harnex session sends to another, a relay header is added
automatically:

```
  ┌──────────┐                        ┌──────────┐
  │ Claude   │  harnex send --id w    │ Codex    │
  │ id=super │ ─────────────────────> │ id=w     │
  └──────────┘                        └──────────┘

  What Codex receives:
  ┌─────────────────────────────────────────────────┐
  │ [harnex relay from=claude id=super at=...T12:00]│
  │ implement plan A                                │
  └─────────────────────────────────────────────────┘
```

If the target agent is busy, the message queues and delivers
automatically when it returns to a prompt:

```
  Sender                        Target (busy)
    │                              │
    │──── POST /send ────────────>│
    │<─── 202 queued ─────────────│
    │                              │
    │  ... target finishes task ...│
    │                              │
    │  (inbox auto-delivers)       │
    │<─── delivered ──────────────│
```

## Detached Sessions & Supervisor Pattern

Spawn workers in the background, send them tasks, wait for results:

```bash
# Spawn workers in tmux windows
harnex run codex --id impl-1 --tmux cx-p1 -- --cd ~/repo/wt-a
harnex run codex --id impl-2 --tmux cx-p2 -- --cd ~/repo/wt-b

# Send work
harnex send --id impl-1 --message "implement feature A"
harnex send --id impl-2 --message "implement feature B"

# Wait for both
harnex wait --id impl-1
harnex wait --id impl-2

# Review phase
harnex run claude --id review --tmux cl-r1
harnex send --id review --message "review changes in wt-a and wt-b"
harnex wait --id review
```

```
  Supervisor (Claude)
    │
    ├── spawn ──> impl-1 (Codex, tmux cx-p1)
    ├── spawn ──> impl-2 (Codex, tmux cx-p2)
    │
    ├── send "implement A" ──> impl-1
    ├── send "implement B" ──> impl-2
    │
    ├── wait impl-1 ✓
    ├── wait impl-2 ✓
    │
    ├── spawn ──> review (Claude, tmux cl-r1)
    ├── send "review changes" ──> review
    └── wait review ✓
```

### Using `--context` on spawn

`--context` passes an initial prompt to the agent with the session ID
auto-included. The spawner decides the content:

```bash
# Fire-and-forget
harnex run codex --id impl-1 --tmux cx-p1 \
  --context "Implement koder/plans/03_auth.md. Commit when done." \
  -- --cd ~/repo/worktree

# Fire-and-wait
harnex run codex --id reviewer --tmux cx-rv \
  --context "You are a code reviewer. Wait for relay messages."
harnex send --id reviewer --message "Review src/auth.rb"
harnex wait --id reviewer
```

## Adapters

Harnex ships adapters for two CLIs:

| Adapter | Launch command | Notes |
|---------|---------------|-------|
| `codex` | `codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen` | Inline mode for screen parsing |
| `claude` | `claude --dangerously-skip-permissions` | Detects workspace trust prompt |

Each adapter handles prompt detection, submit behavior, and blocked
state recognition. The transport layer stays generic.

## Session Registry

Sessions are addressed by ID within a repo:

```bash
harnex run codex               # id: codex
harnex run claude              # id: claude
harnex run codex --id impl-1   # id: impl-1
harnex run codex --id impl-2   # id: impl-2
```

Registry files live at `~/.local/state/harnex/sessions/<repo-hash>--<id>.json`
and contain the port, PID, token, and timestamps.

## File Watch Hooks

```bash
harnex run codex --id worker --watch ./tmp/tick.jsonl
```

When the watched file changes (after 1s debounce), harnex injects:

```
file-change-hook: read ./tmp/tick.jsonl
```

Uses Linux inotify. The file doesn't need to exist at startup.

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `HARNEX_ID` | Default session ID |
| `HARNEX_HOST` | Bind host |
| `HARNEX_PORT` | Force port |
| `HARNEX_BASE_PORT` | Base port (default: 43000) |
| `HARNEX_PORT_SPAN` | Port range (default: 4000) |
| `HARNEX_STATE_DIR` | State directory |
| `HARNEX_SEND_WAIT` | Sender poll timeout (default: 30s) |
| `HARNEX_TRACE=1` | Print backtraces |

Inside a harnex session, these are also set:

| Variable | Purpose |
|----------|---------|
| `HARNEX_SESSION_CLI` | Which CLI (`claude` / `codex`) |
| `HARNEX_SESSION_ID` | Internal instance ID |
| `HARNEX_SESSION_REPO_ROOT` | Repo root path |

## License

MIT
