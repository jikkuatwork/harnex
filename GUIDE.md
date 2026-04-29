# Getting Started with Harnex

You've installed harnex. Here's how to actually use it.

## Recommended mental model

Treat harnex as a local supervisor harness, not as a conversation
bus between agents.

- Start a fresh worker for each step, usually with `--tmux`
- Send one clear task, often by pointing the worker at a file
- Use `--wait-for-idle` as a fence, then inspect with `harnex pane`
- Ask the worker to write its output to a file when the next step
  needs structured input
- Stop the worker when that step is done

For multi-step flows, chain fresh workers with file handoffs:
Codex writes a plan, another Codex implements it, Claude reviews it,
another Codex fixes it.

## Your first session

Start an agent the way you normally would, but through harnex:

```bash
harnex run codex
```

The agent looks and works exactly the same. Harnex runs alongside
it — registering the session, listening for messages, and tracking
whether the agent is busy or idle.

Give it a name so other sessions can find it:

```bash
harnex run codex --id worker
```

## Sending messages

From another terminal:

```bash
harnex send --id worker --message "implement the auth module"
```

If the agent is busy, the message queues and delivers
automatically when the agent is ready. You don't have to wait
or retry. Queueing exists, but the default workflow should still be
one task per fresh worker.

For unattended dispatch, prefer built-in monitoring over external poll loops:

```bash
harnex run codex --id impl --tmux impl --watch --preset impl
```

This adds a foreground watcher that checks idle activity and performs bounded
force-resume nudges. For full flag behavior and event-stream consumers, see
[TECHNICAL.md](TECHNICAL.md) and the built-in monitoring section in
[README.md](README.md).

## Seeing what's running

```bash
harnex status
```

Shows all live sessions for the current repo with their ID, CLI
type, age, and state (prompt/busy).

## Running agents in tmux

This is the recommended way to run multiple agents. Each one gets
its own tmux window you can switch to anytime:

```bash
harnex run codex --id impl --tmux
harnex run claude --id review --tmux
```

Switch between them with your normal tmux keys (`Ctrl-b n`,
`Ctrl-b p`, or `Ctrl-b w` to pick from a list). This is the
easiest way to monitor what each agent is doing — you see exactly
what you'd see if you were running it directly.

For longer-running work, `harnex pane` lets you peek at an
agent's screen without switching windows:

```bash
harnex pane --id impl --lines 30
```

Or watch it live from your current terminal:

```bash
harnex pane --id impl --follow
```

## Sending work and waiting for it to finish

Use `--wait-for-idle` to block until the agent finishes
processing:

```bash
harnex send --id impl --message "implement the plan" --wait-for-idle --timeout 600
```

This is better than separate send + wait commands because there's
no gap where you might check too early and think the agent is
done when it hasn't started yet.

Treat `--wait-for-idle` as the fence, not the report. After the
send returns, use `harnex pane` or `harnex logs` to inspect what
actually happened.

## Sending large prompts

PTY buffers and shell quoting don't love multi-kilobyte inline
messages. For anything longer than a few sentences, write the
task to a file and tell the agent to read it:

```bash
cat > /tmp/task-impl.md <<'EOF'
Implement phase 2 from koder/plans/03_output_streaming.md.

Focus on:
- The HTTP endpoint for streaming output
- Integration with the existing ring buffer
- Tests for the new endpoint

Do not modify the CLI commands.
EOF

harnex send --id impl --message "Read and execute /tmp/task-impl.md"
```

If the task is already written down — a plan file, an issue, a
spec — just point to it:

```bash
harnex send --id impl --message "Implement koder/plans/plan_09_atomic_send_wait.md"
```

This is more reliable, easier to debug (you can read the file to
see exactly what was sent), and avoids quoting headaches.

## Capturing results

For dependable multi-step work, prefer file handoffs over reply
messages.

Examples:

```bash
# Planning
harnex send --id plan --message "Read koder/issues/13_atomic_send_wait.md and write a plan to /tmp/plan-13.md. Do not change code." --wait-for-idle --timeout 600

# Review
harnex send --id review --message "Review the current changes against /tmp/plan-13.md and write findings to /tmp/review-13.md. If clean, say so explicitly." --wait-for-idle --timeout 600
```

Why files work better:

- The next worker can read exactly the same artifact you reviewed
- The supervisor can inspect the artifact without scraping terminal text
- If the session dies, the output still exists

After the worker finishes, inspect the screen:

```bash
harnex pane --id review --lines 60
```

**Return channel for any tmux pane:** Every spawned session gets
`$HARNEX_SPAWNER_PANE` — the tmux pane ID of whoever ran `harnex run`.
The spawned agent can report back via `tmux send-keys`, even if the
invoker isn't a harnex session:

```bash
tmux send-keys -t "$HARNEX_SPAWNER_PANE" "done — results in /tmp/result.md" Enter
```

If you're inside a harnex-managed session, you can also use
`$HARNEX_ID` as the return address with `harnex send`. But file
handoffs remain the preferred primary control flow.

## Stopping agents

```bash
harnex stop --id impl
```

This sends the agent's native exit sequence (e.g. `/exit` for
Codex). The agent shuts down cleanly.

## A reliable supervised workflow

Use fresh instances for each stage. Codex plans and implements.
Claude only reviews.

```bash
# 1. Plan with Codex
harnex run codex --id cx-plan-13 --tmux
harnex send --id cx-plan-13 --message "Read koder/issues/13_atomic_send_wait.md and write a concrete implementation plan to /tmp/plan-13.md. Do not change code." --wait-for-idle --timeout 600
harnex pane --id cx-plan-13 --lines 60
harnex stop --id cx-plan-13

# 2. Implement with a fresh Codex
harnex run codex --id cx-impl-13 --tmux
harnex send --id cx-impl-13 --message "Read /tmp/plan-13.md, implement it, run tests, and write a short summary to /tmp/impl-13.md." --wait-for-idle --timeout 1200
harnex pane --id cx-impl-13 --lines 80
harnex stop --id cx-impl-13

# 3. Review with a fresh Claude
harnex run claude --id cl-rev-13 --tmux
harnex send --id cl-rev-13 --message "Review the current changes against /tmp/plan-13.md. Write findings to /tmp/review-13.md. If there are no issues, say clean." --wait-for-idle --timeout 900
harnex pane --id cl-rev-13 --lines 80
harnex stop --id cl-rev-13
```

If the review finds issues, spawn another fresh Codex worker and tell
it to read `/tmp/review-13.md`, fix the findings, run tests, and write
an updated summary. Then review again with a fresh Claude instance.

## Teaching your agents about harnex

Harnex ships skill files that tell AI agents how to use harnex
commands. Install them globally so every session picks them up:

```bash
harnex skills install
```

This copies the bundled skills (harnex-dispatch, harnex-chain,
harnex-buddy) to `~/.claude/skills/` and symlinks `~/.codex/skills/`
to them. After this, any Claude or Codex session — in any repo — can
use harnex commands without being taught how. The skills activate
automatically when agent collaboration is needed.

For repo-local installs instead, use `--local`.

## Recipes

Tested workflows for common multi-agent patterns. Read them
from the CLI:

```bash
harnex recipes             # list all recipes
harnex recipes show 01     # read one
```

- **Fire and Watch** (`harnex recipes show 01`) — send work to a
  fresh worker, watch its tmux screen, capture the result, stop it.
- **Chain Implement** (`harnex recipes show 02`) — process a
  batch as repeated fire-and-watch: Codex plan/implement,
  Claude review, Codex fix, then review again if needed.
- **Buddy** (`harnex recipes show 03`) — spawn an accountability
  partner for overnight or long-running work. The buddy polls the
  worker's screen and nudges it if it stalls.

## What's next

For the full command reference, flags, HTTP API, and internals,
see [TECHNICAL.md](TECHNICAL.md).
