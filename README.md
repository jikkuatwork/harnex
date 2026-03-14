# Harnex

Make your AI agents work together.

Harnex lets you run multiple AI agents (Claude, Codex) side
by side and have them talk to each other. Each agent keeps
its normal terminal — harnex just connects them.

```
  ┌─────────────────────────────────────────────────┐
  │                                                 │
  │  ┌────────────────┐       ┌────────────────┐    │
  │  │                │ send  │                │    │
  │  │   Claude       ├──────>┤   Codex        │    │
  │  │   id=review    │       │   id=worker    │    │
  │  │                ├<──────┤                │    │
  │  └────────────────┘ reply └────────────────┘    │
  │                                                 │
  └─────────────────────────────────────────────────┘
```

## Install

```bash
git clone https://github.com/jikkujose/harnex.git
ln -s $(pwd)/harnex/bin/harnex ~/.local/bin/harnex
```

Needs Ruby 3.x. No other dependencies.

## Quick Start

**Start an agent:**

```bash
harnex run codex
```

**Start another agent with a name:**

```bash
harnex run claude --id review
```

**See what's running:**

```bash
harnex status
```

**Send a message to an agent:**

```bash
harnex send --id review --message "Summarize the project."
```

That's the core loop: start agents, name them, send messages.

## How It Works

```
  You type:
    harnex run codex --id worker

  Harnex:
    1. Starts codex (terminal works exactly as before)
    2. Registers the session so others can find it
    3. Starts listening for messages

  Now you (or other agents) can:
    harnex send --id worker --message "do something"
    harnex status
    harnex wait --id worker
```

## Commands

### `harnex run` — Start an agent

```bash
harnex run codex
harnex run claude --id review
harnex run codex -- --cd ~/other/repo
```

| Flag            | What it does                          |
|-----------------|---------------------------------------|
| `--id ID`       | Name this session (default: cli name) |
| `--detach`      | Run in background, no terminal        |
| `--tmux [NAME]` | Run in a tmux window you can watch    |
| `--context TXT` | Give the agent a task on startup      |
| `--watch PATH`  | Notify agent when a file changes      |

### `harnex send` — Talk to a running agent

```bash
harnex send --id worker --message "implement plan A"
```

| Flag          | What it does                         |
|---------------|--------------------------------------|
| `--id ID`     | Which agent to talk to               |
| `--message`   | The message text                     |
| `--enter`     | Just press Enter (no new text)       |
| `--no-submit` | Type the text but don't press Enter  |
| `--status`    | Check if the agent is busy or ready  |
| `--force`     | Send even if the agent looks busy    |
| `--async`     | Don't wait for delivery confirmation |

### `harnex status` — See running agents

```
  ID       CLI     AGE      STATE
  ───────  ──────  ───────  ──────
  worker   codex   36s ago  prompt
  review   claude   8s ago  busy
```

### `harnex wait` — Wait for an agent to finish

```bash
harnex wait --id worker
harnex wait --id worker --timeout 300
```

## Agents Talking to Each Other

When one harnex agent sends a message to another, the receiver
automatically sees who sent it:

```
  ┌────────────────┐                  ┌────────────────┐
  │                │  "implement A"   │                │
  │   Claude       ├────────────────>─┤   Codex        │
  │   id=super     │                  │   id=worker    │
  └────────────────┘                  └───────┬────────┘
                                              │
                                   What Codex sees:
                                              │
                            ┌─────────────────┴───────────┐
                            │  [harnex relay              │
                            │    from=claude id=super     │
                            │    at=2026-03-14T12:00]     │
                            │                             │
                            │  implement A                │
                            └─────────────────────────────┘
```

This happens automatically. No setup needed.

### What if the agent is busy?

Messages queue up and deliver when the agent is ready:

```
  Sender                         Receiver (busy)
    │                                │
    ├── "implement plan A" ─────────>│
    │<── queued ─────────────────────┤
    │                                │
    │    ... agent finishes ...      │
    │                                │
    │    (message auto-delivered)    │
    │<── done ───────────────────────┤
```

You don't have to retry. Harnex handles the waiting.

## Background Agents

You don't need a terminal for every agent. Run them in the
background and interact through messages.

**In a tmux window** (you can watch them):

```bash
harnex run codex --id worker --tmux cx-w1
```

Switch to the tmux window anytime to see what the agent is
doing.

**Headless** (no terminal at all):

```bash
harnex run codex --id worker --detach
```

## Supervisor Pattern

One agent can manage others — spawn workers, give them tasks,
and wait for results:

```bash
# Spawn two workers in tmux windows
harnex run codex --id impl-1 --tmux cx-p1 -- --cd ~/wt-a
harnex run codex --id impl-2 --tmux cx-p2 -- --cd ~/wt-b

# Give them tasks
harnex send --id impl-1 --message "implement feature A"
harnex send --id impl-2 --message "implement feature B"

# Wait for both to finish
harnex wait --id impl-1
harnex wait --id impl-2

# Spawn a reviewer
harnex run claude --id review --tmux cl-r1
harnex send --id review --message "review changes"
harnex wait --id review
```

```
  Supervisor
    │
    ├── spawn ──> impl-1 (Codex)
    ├── spawn ──> impl-2 (Codex)
    │
    ├── send "feature A" ──> impl-1
    ├── send "feature B" ──> impl-2
    │
    ├── wait impl-1 ✓
    ├── wait impl-2 ✓
    │
    ├── spawn ──> review (Claude)
    ├── send "review changes" ──> review
    └── wait review ✓
```

## Give Agents Context on Startup

Use `--context` to tell an agent what to do when it starts.
Harnex automatically includes the session ID.

**Fire and forget** — agent works on its own:

```bash
harnex run codex --id impl-1 --tmux cx-p1 \
  --context "Implement the auth feature. Commit when done." \
  -- --cd ~/repo/worktree
```

**Fire and wait** — start, send work later, wait:

```bash
harnex run codex --id reviewer --tmux cx-rv \
  --context "You are a code reviewer."
harnex send --id reviewer --message "Review src/auth.rb"
harnex wait --id reviewer
```

## File Watching

Tell an agent to pay attention when a file changes:

```bash
harnex run codex --id worker --watch ./tmp/status.jsonl
```

When the file changes, the agent gets notified. The file
doesn't need to exist when you start.

## Naming Sessions

If you don't pick a name, harnex uses the agent name:

```bash
harnex run codex               # id: codex
harnex run claude              # id: claude
harnex run codex --id impl-1   # id: impl-1
harnex run codex --id impl-2   # id: impl-2
```

Run as many agents as you want — just give them different
names.

## Supported Agents

| Agent    | Notes                                  |
|----------|----------------------------------------|
| `codex`  | OpenAI Codex CLI                       |
| `claude` | Anthropic Claude Code CLI              |

Adding new agents is straightforward — each one just needs a
small adapter file.

## Going Deeper

For technical details — the HTTP API, state machine, message
queue, adapter internals — see [TECHNICAL.md](TECHNICAL.md).

## License

[MIT](LICENSE)
