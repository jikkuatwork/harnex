# Harnex

Run multiple AI coding agents from your terminal and coordinate them.

Harnex wraps Claude Code and OpenAI Codex (or any terminal CLI) in a
local harness so you can launch agents, send them tasks, watch their
screens, and stop them cleanly — all from the command line.

```bash
gem install harnex
```

Requires **Ruby 3.x**. No other dependencies.

Then ask the CLI what to do next:

```bash
harnex
harnex --help
harnex agents-guide
```

`harnex agents-guide` is the agent-facing reference for dispatch, chain,
buddy, monitoring, and naming patterns. It is packaged in the gem; no skills
or project-local docs are required.

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

Harnex ships CLI-readable agent guides for this pattern:

- **[Dispatch](guides/01_dispatch.md)** — the fire-and-watch pattern:
  spawn an agent, poll its screen, stop it when done
- **[Chain](guides/02_chain.md)** — end-to-end issue-to-code
  workflow: plan, review plan, implement, review code, fix
- **[Buddy](guides/03_buddy.md)** — spawn an accountability partner
  for long-running or overnight work
- **[Monitoring](guides/04_monitoring.md)** — completion signals and
  poll/watch patterns
- **[Naming](guides/05_naming.md)** — session IDs, task files, done markers

Read them from the installed CLI:

```bash
harnex agents-guide dispatch
harnex agents-guide monitoring
```

## Built-in dispatch monitoring

For unattended dispatches, use `--watch` instead of writing a bash poll loop:

```bash
harnex run codex --id cx-impl-42 --watch --preset impl \
  --context "Implement koder/plans/42_plan.md. Run tests and commit when done."
```

`--watch` runs a foreground babysitter that checks session activity every 60s,
force-resumes on stall up to a cap, and exits when the target session exits or
the resume cap is reached.

Presets map to stall policy defaults:

- `impl` -> `--stall-after 8m --max-resumes 1`
- `plan` -> `--stall-after 3m --max-resumes 2`
- `gate` -> `--stall-after 15m --max-resumes 0`

Explicit `--stall-after` and `--max-resumes` flags override preset defaults.

For structured subscriptions, stream JSONL events:

```bash
harnex events --id cx-impl-42 | jq -c '.'
```

Schema details and compatibility policy are documented in
[docs/events.md](docs/events.md).

## Long-running and overnight work

For plain "force-resume on stall" recovery, use
`harnex run --watch --preset impl`.

A **buddy** is for richer reasoning: doc drift checks, semantic sanity checks,
and multi-session correlation. It's still just another harnex session.

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
| `harnex run <cli>` | Start an agent (`--tmux` visible, `--detach` background, `--watch` built-in monitoring) |
| `harnex send --id <id>` | Send a message (queues if busy, `--wait-for-idle` to block until done) |
| `harnex stop --id <id>` | Send the agent's native exit sequence |
| `harnex status` | List running sessions (`--json` for full payloads) |
| `harnex pane --id <id>` | Capture the agent's tmux screen (`--follow` for live) |
| `harnex logs --id <id>` | Read session transcript (`--follow` to tail) |
| `harnex events --id <id>` | Stream structured session events (`--snapshot` for non-blocking dump) |
| `harnex wait --id <id>` | Block until exit or a target state |
| `harnex guide` | Getting started walkthrough |
| `harnex agents-guide` | Agent-facing dispatch, chain, buddy, monitoring, and naming guides |
| `harnex recipes` | Tested workflow patterns |

## Uninstalling

```bash
gem uninstall harnex
```

If you installed harnex skills with an older release, those copies are no
longer used. Remove stale `~/.claude/skills/harnex-*` or
`~/.codex/skills/harnex-*` entries manually if you want to clean them up.

## Going deeper

- [GUIDE.md](GUIDE.md) — getting started walkthrough with examples
- [TECHNICAL.md](TECHNICAL.md) — full command reference, flags, HTTP API, architecture

## License

[MIT](LICENSE)
