# Technical Reference

For what harnex is and whether you'd want it, see
[README.md](README.md). This document covers commands, patterns,
and internals.

## Commands

### `harnex run` — Start an agent

```bash
harnex run codex
harnex run claude --id review
harnex run codex -- --cd ~/other/repo
```

| Flag                | What it does                                                        |
|---------------------|---------------------------------------------------------------------|
| `--id ID`           | Name this session (default: random)                                 |
| `--description`     | Store a short session description                                   |
| `--detach`          | Run in background, no terminal                                      |
| `--tmux [NAME]`     | Run in a tmux window you can watch                                  |
| `--host HOST`       | Bind a specific API host                                            |
| `--port PORT`       | Force a specific API port                                           |
| `--watch`           | Enable blocking babysitter mode (foreground only)                   |
| `--stall-after DUR` | Idle threshold before force-resume (default: `480s`)                |
| `--max-resumes N`   | Max forced resumes before escalation (default: `1`)                 |
| `--preset NAME`     | Watch preset (`impl`, `plan`, `gate`), requires `--watch`           |
| `--watch-file PATH` | Auto-send a file-change hook (`--watch PATH`/`--watch=PATH` legacy) |
| `--context TXT`     | Give the agent a task on startup                                    |
| `--timeout SEC`     | Wait budget for detached registration                               |

### `harnex send` — Talk to a running agent

```bash
harnex send --id worker --message "implement plan A"
```

| Flag              | What it does                           |
|-------------------|----------------------------------------|
| `--id ID`         | Which agent to talk to                 |
| `--message`       | The message text                       |
| `--wait-for-idle` | Block until agent finishes processing  |
| `--repo PATH`     | Resolve session from a repo root       |
| `--cli CLI`       | Filter by CLI type                     |
| `--submit-only`   | Just press Enter (no new text)         |
| `--no-submit`     | Type the text but don't press Enter    |
| `--force`         | Send even if the agent looks busy      |
| `--no-wait`       | Don't wait for delivery confirmation   |
| `--relay`         | Force relay header formatting          |
| `--no-relay`      | Suppress automatic relay headers       |
| `--port` / `--token` | Send directly to a known API port  |
| `--timeout`       | Overall wait budget                    |

### `harnex stop` — Ask an agent to stop

```bash
harnex stop --id worker
harnex stop --id worker --timeout 5
```

Sends the adapter-specific stop sequence. Retries transient
failures for up to the given timeout.

### `harnex status` — See running agents

```
ID      CLI    PID    PORT   AGE  IDLE  STATE   REPO   DESC
worker  codex  12345  43123  36s  12s   prompt  ~/...  -
review  claude 12346  43124   8s  -     busy    ~/...  -
```

Text mode includes an `IDLE` column derived from `log_idle_s` (`-` means no
transcript activity yet).

Use `--json` for full payloads. JSON includes:

- `log_mtime` (ISO8601 or `null`) — transcript file mtime
- `log_idle_s` (Integer or `null`) — seconds since last transcript write

Use `--all` for all repos.

### `harnex wait` — Wait for an agent to finish

```bash
harnex wait --id worker
harnex wait --id worker --until prompt --timeout 300
```

### `harnex logs` — Read session transcripts

```bash
harnex logs --id worker --lines 50
harnex logs --id worker --follow
```

### `harnex pane` — Capture a tmux screen snapshot

```bash
harnex pane --id worker --lines 40
harnex pane --id worker --follow
harnex pane --id worker --json
```

Notes:
- Works only for tmux-backed sessions
- Resolves against the live tmux pane target, not just the harnex session ID
- If a session was started from another worktree, `pane` can fall back to a
  unique cross-repo ID match; use `--repo` when the same ID exists in more
  than one repo root

## Usage Patterns

### Atomic send+wait

Use `--wait-for-idle` instead of separate send + sleep + wait:

```bash
# Replaces: send → sleep 5 → wait --until prompt
harnex send --id cx-1 --message "implement the plan" --wait-for-idle --timeout 600
```

### Agents talking to each other

When one harnex agent sends to another, the receiver sees a
relay header automatically:

```
[harnex relay from=claude id=supervisor at=2026-03-14T12:00]
implement A
```

Messages queue when the agent is busy and auto-deliver when ready.

### Background agents

**tmux** (observable):

```bash
harnex run codex --id worker --tmux cx-w1
```

**Headless** (no terminal):

```bash
harnex run codex --id worker --detach
```

### Supervisor pattern

One agent manages others:

```bash
harnex run codex --id impl-1 --tmux cx-p1 -- --cd ~/wt-a
harnex run codex --id impl-2 --tmux cx-p2 -- --cd ~/wt-b

harnex send --id impl-1 --message "implement feature A" --wait-for-idle --timeout 600
harnex send --id impl-2 --message "implement feature B" --wait-for-idle --timeout 600

harnex run claude --id review --tmux cl-r1
harnex send --id review --message "review changes" --wait-for-idle --timeout 300
```

### Context on startup

```bash
harnex run codex --id impl-1 --tmux cx-p1 \
  --context "Implement the auth feature. Commit when done." \
  -- --cd ~/repo/worktree
```

### File watching

```bash
harnex run codex --id worker --watch-file ./tmp/status.jsonl
```

Agent gets notified when the file changes. File doesn't need to
exist at startup.

Legacy compatibility: `--watch PATH` and `--watch=PATH` still configure
file-hook mode.

## harnex events

`harnex events` streams structured per-session JSONL for orchestrators and
monitoring tooling.

```bash
harnex events --id worker
harnex events --id worker --snapshot
harnex events --id worker --from 2026-04-29T10:00:00Z
harnex events --id worker | jq -c '.'
```

| Flag | What it does |
|------|---------------|
| `--id ID` | Session ID to inspect (required) |
| `--[no-]follow` | Stream appended events (default: follow) |
| `--snapshot` | Print current event file and exit (`--no-follow`) |
| `--from TS` | Replay floor (ISO-8601, inclusive; `ts >= from`) |
| `--repo PATH` | Resolve ID from a specific repo root |
| `--cli CLI` | Filter active-session resolution by CLI |

Exit codes:

- `0` — snapshot completed, or follow mode observed `type: "exited"`
- `1` — operational error (missing stream/session, invalid `--from`,
  stream truncated/disappeared, lookup failure)

Transport file (append-only JSONL):

```
~/.local/state/harnex/events/<repo_hash>--<id>.jsonl
```

Each row uses schema v1 with envelope fields `schema_version`, `seq`, `ts`,
`id`, and `type`. Emitted today: `started`, `send`, `exited`. `send.msg` is a
200-character preview with `msg_truncated` when shortened.

Schema details and compatibility guarantees are in [docs/events.md](docs/events.md).

## Architecture

```
 bin/harnex
   │
   └── lib/harnex.rb (loader)
         │
         ├── CLI          dispatch: run / send / status / wait / stop
         ├── Runner        spawn sessions (foreground/detach/tmux)
         ├── Sender        resolve target, inject text
         ├── Status        list live sessions
         ├── Waiter        block until session exits
         ├── Stopper       send stop sequence
         │
         ├── Session       PTY lifecycle, HTTP server, registry
         ├── SessionState  state machine (prompt/busy/blocked)
         ├── Inbox         per-session message queue
         ├── Message       queued message struct
         │
         ├── FileChangeHook   inotify file watcher
         └── LinuxInotify     raw inotify via Fiddle

 lib/harnex/adapters/
   ├── base.rb     adapter interface
   ├── generic.rb  fallback adapter for any CLI
   ├── codex.rb    codex-specific behavior
   └── claude.rb   claude-specific behavior
```

## Session Lifecycle

Foreground execution is the default operating mode for a human directly using
`harnex run`. For agent-to-agent delegation, a visible tmux session is the
preferred interactive mode because it keeps the peer's work observable.

Headless/background execution (`--detach`) should still be treated as opt-in.

When you run `harnex run codex --id worker`:

```
 1. Parse wrapper options, build adapter
 2. Validate the target binary before spawn
 3. Spawn the agent CLI under a PTY (pseudoterminal)
 4. Generate a random bearer token for API auth
 5. Pick a port:
      hash(repo_root + id) % port_span + base_port
      walk forward until a free port is found
 6. Start HTTP server on 127.0.0.1:<port>
 7. Write registry file:
      ~/.local/state/harnex/sessions/<repo_hash>--<id>.json
      and open transcript file:
      ~/.local/state/harnex/output/<repo_hash>--<id>.log
      and open events file:
      ~/.local/state/harnex/events/<repo_hash>--<id>.jsonl
 8. Start background threads:
      - PTY reader (screen buffer)
      - State machine (adapter parses screen for state)
      - Inbox delivery (queue -> inject when prompt)
      - File watcher (if --watch was given)
 9. Relay terminal I/O between user and agent
10. On exit: clean up registry, write exit status
```

## PTY and Screen Parsing

Harnex spawns the agent inside a pseudoterminal (PTY). This
preserves the agent's full terminal UI while letting harnex:

- Read screen output into a ring buffer
- Feed the buffer to the adapter for state detection
- Inject text by writing to the PTY input

The screen text includes raw terminal escape sequences. The
adapter's `normalized_screen_text` strips ANSI and OSC codes
before parsing.

## Adapter Contract

Each adapter in `lib/harnex/adapters/` implements:

| Method                    | Purpose                         |
|---------------------------|---------------------------------|
| `base_command`            | CLI args to launch the agent    |
| `input_state(screen)`     | Parse screen -> state hash      |
| `build_send_payload(...)` | Build injection with submit     |
| `inject_exit(writer)`     | Send adapter-specific stop text |
| `infer_repo_path(argv)`   | Extract repo path from CLI args |
| `wait_for_sendable(...)`  | Wait strategy before sending    |

### Input States

The adapter reads the screen and returns a state hash:

| State                    | `input_ready` | Meaning               |
|--------------------------|---------------|-----------------------|
| `prompt`                 | `true`        | Ready for input       |
| `session`                | `nil`         | Agent is working      |
| `workspace-trust-prompt` | `false`       | Needs Enter to confirm|
| `confirmation`           | `false`       | Modal confirmation    |
| `unknown`                | `nil`         | Can't determine       |

### Codex Adapter (default — JSON-RPC `app-server`)

- `transport :stdio_jsonrpc` — speaks JSON-RPC 2.0 over the
  subprocess's stdin/stdout, one JSON object per line.
- Launches `codex app-server` (Codex CLI ≥ 0.128.0; verify with
  `harnex doctor`).
- Notifications (`turn/started`, `turn/completed`, `item/completed`,
  `error`, `thread/compacted`, …) fan into the events log.
  `task_complete` is the harnex-side event for `turn/completed`.
- Disconnect is detected from JSON-RPC error responses, subprocess
  EOF, parse errors, or a server `error` notification — no screen
  regex required.
- Synthesized transcript: `item/completed` text payloads stream to
  both the output log and STDOUT so tmux/pane workflows continue to
  work without a real PTY.
- See `docs/codex-appserver.md` for the full mapping table and
  troubleshooting.

#### Codex Adapter (legacy PTY — `--legacy-pty`, removal in 0.7.0)

- Launches with `--no-alt-screen` for inline screen output
- Detects prompt by looking for `›` prefix in recent lines
- Multi-step submit: types text, then sends Enter after a
  75ms delay (lets the UI process the input)

### Claude Adapter

- Detects workspace trust prompt ("Quick safety check")
- Allows `--submit-only` to clear the trust prompt
- Detects prompt via `--INSERT--` marker or `›` prefix
- Multi-step submit: types text, then sends Enter after a
  short delay so pasted prompts are actually submitted

## State Machine

`SessionState` tracks the agent's readiness:

```
                  ┌──────────┐
       ┌─────────│  unknown  │──────────┐
       │         └──────────┘           │
       ▼                                ▼
 ┌──────────┐    screen change    ┌──────────┐
 │  prompt   │ <───────────────── │   busy   │
 │           │ ────────────────>  │          │
 └──────────┘    screen change    └──────────┘
       │                                │
       ▼                                ▼
 ┌──────────┐                    ┌──────────┐
 │ blocked  │                    │ blocked  │
 └──────────┘                    └──────────┘
```

- Uses a Mutex + ConditionVariable for thread-safe access
- `wait_for_prompt(timeout)` blocks until state == `:prompt`
- State is updated by the PTY reader thread calling the
  adapter's `input_state` on each screen change

## Inbox and Message Queue

Each session has an `Inbox` with a background delivery thread:

```
 harnex send ──> POST /send ──> Inbox#enqueue
                                  │
                    ┌─────────────┴──────────────┐
                    │                             │
              prompt + empty queue?          otherwise
                    │                             │
              deliver_now()              push to @queue
              return 200                 return 202
                                              │
                                    delivery_loop thread
                                    wait_for_prompt()
                                    deliver_now()
```

### Message Lifecycle

| Status      | Meaning                              |
|-------------|--------------------------------------|
| `queued`    | In the queue, waiting for delivery   |
| `delivered` | Injected into agent's terminal       |
| `failed`    | Injection raised an error            |

Poll status with `GET /messages/:id`.

## HTTP API

All endpoints are on `127.0.0.1:<port>`. Every request needs
the bearer token from the registry file.

### `GET /status`

Returns JSON:

```json
{
  "ok": true,
  "session_id": "abc123",
  "repo_root": "/path/to/repo",
  "cli": "codex",
  "id": "worker",
  "description": "implement auth module",
  "pid": 12345,
  "host": "127.0.0.1",
  "port": 43123,
  "command": ["codex", "--no-alt-screen"],
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

### `POST /send`

Send JSON body:

```json
{
  "text": "implement plan A",
  "submit": true,
  "enter_only": false,
  "force": false
}
```

- **200** with `"status": "delivered"` — sent immediately
- **202** with `"status": "queued"` and `message_id` — agent
  is busy, message will auto-deliver
- **400** — missing text or bad request
- **409** — agent not ready (use `--force` to override)
- **503** — inbox is full

### `POST /stop`

Tells the session adapter to inject its stop sequence.
The `harnex stop` CLI retries transient API failures for up
to its `--timeout` budget before returning exit code 124.

### `GET /messages/:id`

Check delivery status of a queued message.

### `GET /health`

Alias for `/status`.

## Session Registry

Registry files at `~/.local/state/harnex/sessions/`:

```
<repo_hash>--<normalized_id>.json
```

The repo hash is a hex digest of the git root path. The ID is
normalized: lowercased, non-alphanumeric chars replaced with
dashes, leading/trailing dashes stripped.

Contents: port, PID, token, CLI, repo root, timestamps,
injection counters, agent state, inbox stats.

Cleaned up on normal exit. Stale files (dead PID) are ignored
during lookups.

## Exit Status

When a session exits, harnex writes:

```
~/.local/state/harnex/exits/<repo_hash>--<normalized_id>.json
```

This lets `harnex wait` return exit info even if the session
registry entry is already gone.

## Output Transcript

Every session also writes a repo-keyed transcript:

```
~/.local/state/harnex/output/<repo_hash>--<normalized_id>.log
```

- PTY output is appended as bytes are read
- The transcript is opened in append mode, so reusing an ID
  does not wipe prior output
- `output_log_path` is exposed via `status --json` and
  detached `run` responses
- The transcript is the source of truth for the planned
  `harnex logs` operator interface

## Relay Headers

When `harnex send` detects it is running inside a harnex
session (via `HARNEX_SESSION_ID` env) and the target is a
different session, it prepends:

```
[harnex relay from=<cli> id=<sender_id> at=<timestamp>]
```

Control with `--relay` (force) or `--no-relay` (suppress).

Already-wrapped messages (starting with `[harnex relay`) are
not double-wrapped.

## File Watching

`--watch PATH` creates a `FileChangeHook` using Linux inotify
(via Fiddle, no gem needed).

- Watches the file's parent directory for write/create events
- 1 second debounce: waits for quiet time before triggering
- Injects `file-change-hook: read <path>` when triggered
- Creates the parent directory if needed
- File does not need to exist at startup

## Port Selection

Ports are deterministic to keep things predictable:

```
hash = Digest::SHA256.hexdigest(repo_root + id)
start = (hash[0..7].to_i(16) % port_span) + base_port
```

Then walks forward from `start` until a free port is found.

Defaults: base `43000`, span `4000` (range 43000–46999).

## Concurrency

Harnex uses Ruby threads, not processes:

- **PTY reader** — reads agent output into screen buffer
- **State poller** — feeds screen to adapter for state
- **Inbox delivery** — dequeues messages when prompt detected
- **HTTP server** — one thread per connection
- **File watcher** — inotify read loop (if enabled)

All shared state is protected by `Mutex`. The `SessionState`
and `Inbox` classes use `ConditionVariable` for signaling.

## Skill Files

Harnex ships bundled skills that teach agents the orchestration workflow and
dispatch discipline. The canonical collaboration skill is:

```
skills/harnex-dispatch/SKILL.md
```

### What's in the skill

The dispatch skill tells agents:

- How to detect they're inside a harnex session (env vars)
- How to define return channels before delegation
- How to send short, file-referenced tasks with explicit reply instructions
- How to send messages, check status, spawn workers, and stop safely
- How to use `--context`, `--force`, `--no-wait`
- Relay header format and behavior
- Collaboration patterns (reply, supervisor, file watch)
- Safety rules (confirm before sending, no auto-loops)

### How agents load skills

Claude and Codex both support a `skills/` directory. When a
skill is present, the agent can use harnex commands without
being told how — the skill provides the instructions.

Skill files use YAML frontmatter:

```yaml
---
name: harnex-dispatch
description: Fire & Watch dispatch pattern...
allowed-tools: Bash(harnex *)
---
```

The `allowed-tools` field grants the agent permission to run
`harnex` commands without asking for approval each time.

### Installing bundled skills

Use the installer command instead of manual symlinks:

```bash
harnex skills install            # all canonical skills
harnex skills install harnex     # compatibility alias -> harnex-dispatch
harnex skills install --local    # install into current repo only
```

Compatibility aliases accepted by the installer:

- `harnex` -> `harnex-dispatch`
- `dispatch` -> `harnex-dispatch`
- `chain-implement` -> `harnex-chain`

### Skill directory structure

```
 ~/.claude/skills/
   └── harnex-dispatch
         └── SKILL.md

 ~/.codex/skills/
   └── harnex-dispatch -> ~/.claude/skills/harnex-dispatch
         └── SKILL.md
```

Deprecated installed names (`harnex`, `dispatch`, `chain-implement`) are
cleaned automatically during install and uninstall.

## Known Limitations

- Adapter prompt detection is heuristic-based. It works well
  but can misread unusual screen output.
- No read-only HTTP output endpoint for local dashboards (use
  `harnex pane --follow` or `harnex logs --follow` instead).
- File watching: inotify on Linux, stat-polling fallback on
  macOS/other (works everywhere, inotify is just faster).
- The HTTP server is a simple socket server, not a full
  framework. One thread per connection, no keep-alive.

## Dependencies

- Ruby 3.x standard library only
- No gems required
- Uses: `io/console`, `pty`, `socket`, `json`, `net/http`,
  `digest`, `fileutils`, `shellwords`, `fiddle` (for inotify)
