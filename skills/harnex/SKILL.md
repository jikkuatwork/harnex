---
name: harnex
description: Collaborate with other AI agents (Codex, Claude) via harnex. Use when the user asks to send a message to another agent, check agent sessions, spawn workers, relay instructions, or coordinate multi-agent work. Also activates when incoming messages contain "[harnex relay" headers.
allowed-tools: Bash(harnex *)
---

# Harnex — Cross-Agent Collaboration

Harnex wraps interactive terminal agents (Claude Code, Codex) and opens a local
control plane so they can discover and message each other. You use it to **send
messages to a peer agent**, **check session status**, **spawn worker sessions**,
and **wait for them to finish**.

## Detect your context

Check environment variables to understand your role:

| Variable | Meaning |
|----------|---------|
| `HARNEX_SESSION_CLI` | Which CLI you are (`claude` or `codex`) |
| `HARNEX_ID` | Your session ID |
| `HARNEX_SESSION_REPO_ROOT` | Repo root this session is scoped to |
| `HARNEX_SESSION_ID` | Internal instance identifier |

If these are set, you are **inside a harnex session** and can send messages to
peer sessions or spawn new worker sessions.

## Core commands

### Send a message to a peer agent

```bash
harnex send --id <ID> --message "<text>"
```

- `--id` targets a specific session by its unique ID
- `--message` is the prompt text injected into the peer's terminal
- Message is auto-submitted (peer receives it as a prompt)
- `--no-submit` types without pressing Enter
- `--force` sends even if peer UI is not at a prompt (bypasses queue)
- `--enter` sends only Enter (submit what's already in the input box)
- `--async` returns immediately with a message_id (don't wait for delivery)
- `--cli` filters by CLI type when multiple sessions share resolution scope

When the target agent is busy, the message is **queued** (HTTP 202) and
delivered automatically when the agent returns to a prompt. The sender polls
until delivery completes (up to `--wait` seconds, default 30).

**Multi-line messages**: use a heredoc:

```bash
harnex send --id worker-1 --message "$(cat <<'EOF'
Line one of the message.
Line two of the message.
EOF
)"
```

### Check session status

```bash
harnex status            # sessions for current repo
harnex status --all      # sessions across all repos
```

Shows live sessions with their ID, CLI, port, PID, age, and input state.

### Inspect a specific session

```bash
harnex send --id <ID> --status
```

Returns JSON with input state, agent state, inbox stats, injection count,
watch config, and timestamps.

### Spawn a detached worker session

```bash
# Headless (no terminal)
harnex run codex --id impl-1 --detach -- --cd /path/to/worktree

# In a tmux window (observable)
harnex run codex --id impl-1 --tmux cx-p1 -- --cd /path/to/worktree
```

- `--detach` starts the session in the background, returns JSON with pid/port
- `--tmux` creates a tmux window (implies `--detach`)
- `--tmux NAME` sets a custom window title (keep names terse: `cx-p3`, `cl-r3`)
- `--context TEXT` sets an initial prompt with session ID auto-included
- Returns immediately; use `harnex send` to inject work, `harnex wait` to block

#### Using `--context` to orient spawned agents

`--context` prepends a context string as the agent's initial prompt, with the
session ID automatically included as `[harnex session id=<ID>]`. The spawner
decides what context to provide — harnex only adds the session ID.

```bash
# Fire-and-forget: give the task upfront
harnex run codex --id impl-1 --tmux cx-p1 \
  --context "Implement the feature in koder/plans/03_auth.md. Commit when done." \
  -- --cd /path/to/worktree

# Fire-and-wait: give context, then send work separately
harnex run codex --id reviewer --tmux cx-rv \
  --context "You are a code reviewer. Wait for instructions via harnex relay messages." \
  -- --cd /path/to/repo
harnex send --id reviewer --message "Review the changes in src/auth.rb"
harnex wait --id reviewer
```

The context string is the spawner's responsibility — tailor it to the use case.

### Wait for a session to exit

```bash
harnex wait --id impl-1
harnex wait --id impl-1 --timeout 300
```

Blocks until the session process exits. Returns JSON with exit code and timing.
Exit code 124 on timeout.

## Relay headers

When you send from inside a harnex session to a **different** session, harnex
automatically prepends a relay header:

```
[harnex relay from=claude id=supervisor at=2026-03-14T12:00:00+04:00]
<your message>
```

The peer sees this header and knows the message came from another agent. When
you **receive** a message with a `[harnex relay ...]` header, treat it as a
prompt from the peer agent — read the body and respond to it.

Control relay behavior:
- `--relay` forces the header even outside a session
- `--no-relay` suppresses the header

## Collaboration patterns

### Reply to a peer

When the user (or a relay message) asks you to reply to the other agent:

```bash
harnex send --id <TARGET_ID> --message "Your response here"
```

### Supervisor pattern

A supervisor session spawns workers, sends them tasks, and waits for completion:

```bash
# Spawn workers
harnex run codex --id impl-1 --tmux cx-p1 -- --cd ~/repo/wt-feature-a
harnex run codex --id impl-2 --tmux cx-p2 -- --cd ~/repo/wt-feature-b

# Send work
harnex send --id impl-1 --message "implement plan 150"
harnex send --id impl-2 --message "implement plan 151"

# Wait for completion
harnex wait --id impl-1
harnex wait --id impl-2

# Review phase
harnex run claude --id review-1 --tmux cl-r1
harnex send --id review-1 --message "review changes in wt-feature-a"
harnex wait --id review-1
```

### File watch hook

Sessions can watch a shared file (e.g. `--watch ./tmp/tick.jsonl`). When the
file changes, harnex injects a `file-change-hook: read <path>` message. If you
receive this hook, read the file and act on its contents.

## Important rules

1. **Always confirm with the user before sending** unless they explicitly asked
   you to send a specific message. Sending injects a prompt into the peer's
   terminal — it's an action visible to others.
2. **Never auto-loop** relay conversations. One send per user request unless
   told otherwise.
3. **Check status first** if unsure whether a peer is running: `harnex status`
4. **Use `--force` sparingly** — it bypasses the inbox queue and adapter
   readiness checks. Can corrupt peer input if it's mid-response.
5. **Relay headers are automatic** when sending from inside a session. Don't
   manually prepend them.
6. When composing a message to send, be concise and actionable — the peer agent
   receives it as a prompt and will act on it.
