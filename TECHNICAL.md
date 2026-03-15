# Technical Reference

This document covers the internals of harnex. For usage and
examples, see [README.md](README.md).

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

### Codex Adapter

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

Harnex ships a skill file that teaches AI agents how to use
harnex commands. The file lives at:

```
skills/harnex/SKILL.md
```

### What's in the skill

The skill tells agents:

- How to detect they're inside a harnex session (env vars)
- How to send messages, check status, spawn workers
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
name: harnex
description: Collaborate with other AI agents...
allowed-tools: Bash(harnex *)
---
```

The `allowed-tools` field grants the agent permission to run
`harnex` commands without asking for approval each time.

### Symlinking the skill

To make the skill available globally (not just in the harnex
repo), symlink it into each agent's skill directory:

```bash
# For Claude Code
ln -s /path/to/harnex/skills/harnex \
      ~/.claude/skills/harnex

# For Codex
ln -s /path/to/harnex/skills/harnex \
      ~/.codex/skills/harnex
```

After symlinking, any Claude or Codex session — in any repo —
can use harnex commands. The skill activates automatically
when the user mentions agent collaboration or when a relay
message arrives.

### Skill directory structure

```
 ~/.claude/skills/
   └── harnex -> /path/to/harnex/skills/harnex
         └── SKILL.md

 ~/.codex/skills/
   └── harnex -> /path/to/harnex/skills/harnex
         └── SKILL.md
```

The symlink points to the `skills/harnex/` directory (not the
file directly), so updates to `SKILL.md` in the repo are
picked up immediately.

## Known Limitations

- Adapter prompt detection is heuristic-based. It works well
  but can misread unusual screen output.
- There is still no first-class `harnex logs` command for
  reading or following transcript files.
- There is still no read-only HTTP output endpoint for local
  dashboards or other tools.
- File watching uses Linux inotify. No macOS/Windows support.
- The HTTP server is a simple socket server, not a full
  framework. One thread per connection, no keep-alive.

## Dependencies

- Ruby 3.x standard library only
- No gems required
- Uses: `io/console`, `pty`, `socket`, `json`, `net/http`,
  `digest`, `fileutils`, `shellwords`, `fiddle` (for inotify)
