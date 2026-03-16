# Getting Started with Harnex

You've installed harnex. Here's how to actually use it.

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
or retry.

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

## Getting results back

When you delegate work to an agent, tell it how to report back.
Otherwise it finishes silently and you have to go dig through its
output.

The clearest pattern: tell the agent to send a message back to
you when it's done.

```bash
harnex send --id impl --message "$(cat <<'EOF'
Implement the auth module from koder/plans/plan_04_auth.md.
Run tests after.

When done, send a summary back:
  harnex send --id review --message "<what you did, test results>"
EOF
)"
```

Now you can wait for the reply instead of guessing when the
agent finished or scraping its terminal output.

If you're inside a harnex session yourself (as a supervised
agent), use `$HARNEX_ID` as the return address:

```bash
harnex send --id impl --message "Implement the plan. When done: harnex send --id $HARNEX_ID --message '<summary>'"
```

## Stopping agents

```bash
harnex stop --id impl
```

This sends the agent's native exit sequence (e.g. `/exit` for
Codex). The agent shuts down cleanly.

## A typical multi-agent workflow

Put it all together — implement a feature across two agents:

```bash
# Start agents in tmux
harnex run codex --id impl --tmux
harnex run claude --id review --tmux

# Write the task (it's long)
cat > /tmp/task.md <<'EOF'
Implement issue #13 following koder/plans/plan_09.md.
Run the test suite when done.
When finished, report back: harnex send --id review --message "<summary>"
EOF

# Send and wait
harnex send --id impl --message "Read and execute /tmp/task.md" --wait-for-idle --timeout 600

# Check on them anytime with tmux (Ctrl-b w) or:
harnex pane --id impl --lines 20
harnex status

# Stop when done
harnex stop --id impl
harnex stop --id review
```

## Teaching your agents about harnex

Harnex ships a skill file that tells AI agents how to use harnex
commands. To make it available globally:

```bash
# For Claude Code
ln -s /path/to/harnex/skills/harnex ~/.claude/skills/harnex

# For Codex
ln -s /path/to/harnex/skills/harnex ~/.codex/skills/harnex
```

After this, any Claude or Codex session — in any repo — can use
harnex commands without being taught how. The skill activates
automatically when agent collaboration is needed.

## Recipes

Tested workflows for common multi-agent patterns. Read them
from the CLI:

```bash
harnex recipes             # list all recipes
harnex recipes show 01     # read one
```

- **Fire and Watch** (`harnex recipes show 01`) — send work to a
  worker, poll its tmux screen until idle, capture the result.
- **Chain Implement** (`harnex recipes show 02`) — process a
  batch of plans in series: implement (Codex) → review (Claude)
  → fix (Codex).

## What's next

For the full command reference, flags, HTTP API, and internals,
see [TECHNICAL.md](TECHNICAL.md).
