# Harnex

Run multiple AI coding agents from your terminal and coordinate them.

Harnex wraps Claude Code and OpenAI Codex (or any terminal CLI) in a
local harness so you can launch agents, send them tasks, watch their
screens, and stop them cleanly — all from the command line.

```bash
gem install harnex
```

Requires **Ruby 3.x**. No other dependencies.

Then install workflow skills into your repo so agents can use them:

```bash
harnex skills install
```

This adds orchestration skills (harnex-dispatch, harnex-chain, harnex-buddy)
that Claude Code and Codex pick up automatically.

## What it does

```bash
# Start an agent in tmux
harnex run codex --id planner --tmux

# Send it a task and wait for it to finish
harnex send --id planner --message "Write a plan to /tmp/plan.md" --wait-for-idle

# Peek at what it's doing
harnex pane --id planner --lines 30

# Stop it
harnex stop --id planner
```

That's the core loop. Start a fresh agent for each step, hand it one
job, watch it work, stop it when done.

## Why use this

- **You want agents to plan, implement, review, and fix — in sequence.**
  Codex writes code. Claude reviews it. Another Codex fixes the review
  findings. Each step is a fresh agent with clean context.

- **You want to see what agents are doing.** `harnex pane` shows
  the agent's live terminal. No black boxes.

- **You don't want to babysit.** Send a task with `--wait-for-idle`,
  walk away, check back when it's done.

- **You want local-only orchestration.** Everything runs on your
  machine. No cloud services, no API keys beyond what the agents need.

## When you wouldn't use this

- You only use one agent at a time (just run it directly)
- You need cloud-hosted orchestration
- Your agents aren't terminal-based

## Supported agents

| Agent | Support |
|-------|---------|
| Claude Code | Full (prompt detection, stop sequence, vim mode) |
| OpenAI Codex | Full (prompt detection, stop sequence) |
| Any terminal CLI | Generic wrapping (everything works except smart prompt detection) |

## Multi-agent workflows

The real power is chaining agents together:

```bash
# 1. Codex writes a plan
harnex run codex --id cx-plan --tmux
harnex send --id cx-plan --message "Plan the auth module, write to /tmp/plan.md" --wait-for-idle
harnex stop --id cx-plan

# 2. Fresh Codex implements the plan
harnex run codex --id cx-impl --tmux
harnex send --id cx-impl --message "Implement /tmp/plan.md, run tests" --wait-for-idle
harnex stop --id cx-impl

# 3. Claude reviews the implementation
harnex run claude --id cl-review --tmux
harnex send --id cl-review --message "Review changes against /tmp/plan.md, write /tmp/review.md" --wait-for-idle
harnex stop --id cl-review
```

Harnex ships workflow skills that automate this pattern:

- **[Dispatch](skills/harnex-dispatch/SKILL.md)** — the fire-and-watch pattern:
  spawn an agent, poll its screen, stop it when done
- **[Chain](skills/harnex-chain/SKILL.md)** — end-to-end issue-to-code
  workflow: plan, review plan, implement, review code, fix
- **[Buddy](skills/harnex-buddy/SKILL.md)** — spawn an accountability partner
  for long-running or overnight work

Install skills so agents can use them:

```bash
harnex skills install
```

## Long-running and overnight work

A **buddy** is a second agent that watches something and acts on it.
It's just another harnex session — no special monitoring code, no
configuration. The buddy is an LLM, so it reasons about what it sees
rather than pattern-matching.

### Example: keep a worker from stalling

Spawn a buddy alongside a long-running implementation worker:

```bash
harnex run codex --id worker-42 --tmux
harnex run claude --id buddy-42 --tmux
harnex send --id buddy-42 --message "$(cat <<'EOF'
Watch harnex session worker-42.
Every 5 minutes: run `harnex pane --id worker-42 --lines 30`.
If it looks stuck at a prompt with no progress for 10+ minutes,
nudge it: `harnex send --id worker-42 --message "Continue your task."`.
When it exits, report back:
  tmux send-keys -t "$HARNEX_SPAWNER_PANE" "worker-42 done" Enter
EOF
"
```

### Example: watch for doc drift during implementation

A buddy that checks whether a worker's code changes have left
docs out of date:

```bash
harnex run codex --id worker-99 --tmux
harnex run claude --id buddy-99 --tmux
harnex send --id buddy-99 --message "$(cat <<'EOF'
Watch harnex session worker-99.
Every 5 minutes: run `harnex pane --id worker-99 --lines 30`.
When the worker goes idle after making changes, run `git diff --name-only`
and check whether any changed code has corresponding docs (README, GUIDE,
inline comments) that are now stale. If so, nudge the worker:
  harnex send --id worker-99 --message "Docs may be stale — check README
  sections related to <specific area>."
When the worker exits, report a summary to the invoker:
  tmux send-keys -t "$HARNEX_SPAWNER_PANE" "worker-99 done. Doc drift: <yes/no>" Enter
EOF
"
```

### The invoker doesn't need to be a harnex session

Every spawned session gets `$HARNEX_SPAWNER_PANE` — the tmux pane ID
of whoever ran `harnex run`. The buddy can report back to a plain
Claude Code session, a Codex session, or any tmux pane:

```bash
tmux send-keys -t "$HARNEX_SPAWNER_PANE" "worker-42 finished" Enter
```

See [recipes/03_buddy.md](recipes/03_buddy.md) for the full pattern.

## All commands

| Command | What it does |
|---------|-------------|
| `harnex run <cli>` | Start an agent (`--tmux` for a visible window, `--detach` for background) |
| `harnex send --id <id>` | Send a message (queues if busy, `--wait-for-idle` to block until done) |
| `harnex stop --id <id>` | Send the agent's native exit sequence |
| `harnex status` | List running sessions (`--json` for full payloads) |
| `harnex pane --id <id>` | Capture the agent's tmux screen (`--follow` for live) |
| `harnex logs --id <id>` | Read session transcript (`--follow` to tail) |
| `harnex wait --id <id>` | Block until exit or a target state |
| `harnex guide` | Getting started walkthrough |
| `harnex recipes` | Tested workflow patterns |
| `harnex skills install` | Install bundled skills for Claude/Codex |
| `harnex skills uninstall` | Remove installed skills |

## Uninstalling

```bash
harnex skills uninstall   # remove skills from ~/.claude/ and ~/.codex/
gem uninstall harnex
```

Run `harnex skills uninstall` before removing the gem — installed skills
persist in `~/.claude/skills/` and won't be cleaned up by `gem uninstall`.

## Going deeper

- [GUIDE.md](GUIDE.md) — getting started walkthrough with examples
- [TECHNICAL.md](TECHNICAL.md) — full command reference, flags, HTTP API, architecture

## License

[MIT](LICENSE)
