# Getting Started with Harnex

You've installed harnex. Here's how to actually use it.

## Recommended mental model

Treat harnex as a local supervisor harness, not as a conversation
bus between agents.

- Start a fresh worker for each step, usually with `--tmux`
- Give one clear startup task with `--context` (or `--context-file`); add `--auto-stop` for one-shot work
- Monitor existing visible work with `harnex watch --until done`
- Use `--wait-for-idle` only as a follow-up-send fence, then verify the artifact
- Ask the worker to write its output to a file when the next step needs it
- Stop completed interactive workers promptly

For multi-step flows, chain fresh workers with file handoffs:
Pi writes a plan, a fresh Pi implements it, Claude (or a fresh Pi
lane) reviews it, another fresh Pi fixes it.

## Your first session

Pi is the default worker. Check that the installed Pi is new enough
(0.80.4 or later), then start it through harnex:

```bash
harnex doctor
harnex run pi
```

Harnex runs Pi in its structured RPC mode (`pi --mode rpc`) and
prints the session as a transcript. Harnex runs alongside it —
registering the session, listening for messages, and tracking
whether the agent is busy or idle. Claude Code, OpenCode, or any
other terminal CLI (`harnex run claude`) runs under a PTY instead and
looks exactly as it does when run directly.

Give it a name so other sessions can find it:

```bash
harnex run pi --id pi-i-13
```

Session IDs follow `<cli>-<role>-<tag>`: `pi-p-13` plans issue 13,
`pi-i-13` implements it, `pi-f-13` fixes it, and `cl-r-13` is a
Claude reviewer. See `harnex agents-guide naming`.

## Sending messages

From another terminal:

```bash
harnex send --id pi-i-13 --message "implement the auth module"
```

If the agent is busy, you don't have to wait or retry: a busy Pi
worker takes the message at once as a follow-up and runs it when the
current turn ends, and other agents queue it until they are back at a
prompt. Follow-ups exist, but the default workflow should still be
one task per fresh worker.

For unattended visible dispatch, prefer the native work-level watcher over
external poll loops:

```bash
harnex run pi --id pi-i-13 --tmux pi-i-13 \
  --context "Read and execute /tmp/task-impl-13.md" --auto-stop
harnex watch --id pi-i-13 --until done --max-wait 90m
```

Or launch and wait in one call. `--wait-done` blocks until the first
turn's result and prints it; the worker's reply is
`turn_result.final_message`. On exit 124 the worker keeps going; run
the `resume` command the output names.

```bash
harnex run pi --id pi-i-13 --tmux pi-i-13 \
  --context "Read and execute /tmp/task-impl-13.md" \
  --auto-stop --wait-done --wait-timeout 9m -- --no-approve
```

Pi RPC cannot show Pi's project-trust prompt, so unattended runs pass
Pi `--approve` or `--no-approve` after `--`.

`harnex run --watch --preset impl` is a separate foreground launch-and-stall
babysitter; do not combine it with `--tmux` or `--detach`. For full flag
behavior and event-stream consumers, see
[TECHNICAL.md](TECHNICAL.md) and the built-in monitoring section in
[README.md](README.md).

## Asking a quick question

For a read-only question — a second opinion, an explanation, a quick
review — `harnex ask` runs a Pi worker in a tmux window and prints
only its answer:

```bash
harnex ask "Which module parses the dispatch rows, and is it tested?"
harnex ask --model foundry-zyt/gpt-6.1-sol --file /tmp/question.md --timeout 9m
```

The worker gets read-only tools and stops when it has answered. Add
`--write` to let it edit files and run commands.

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
harnex run pi --id pi-i-13 --tmux pi-i-13
harnex run claude --id cl-r-13 --tmux cl-r-13
```

Pass the same value to `--id` and `--tmux` so status, panes, logs,
and the tmux window name all line up.

Switch between them with your normal tmux keys (`Ctrl-b n`,
`Ctrl-b p`, or `Ctrl-b w` to pick from a list). This is the
easiest way to monitor what each agent is doing. Claude's window
shows its normal TUI; Pi's shows harnex's transcript of the RPC
session rather than Pi's own TUI.

For longer-running work, `harnex pane` lets you peek at an
agent's screen without switching windows:

```bash
harnex pane --id pi-i-13 --lines 30
```

Or watch it live from your current terminal:

```bash
harnex pane --id pi-i-13 --follow
```

## Parallel lanes in worktrees

To run several workers at once, give each lane its own git worktree.
`--cwd` starts Pi in the worktree, `--root` keeps the session
attributed to your main checkout, and harnex credits each lane with
its own commits:

```bash
git worktree add ../wt-13 -b issue-13
git worktree add ../wt-14 -b issue-14
harnex run pi --id pi-i-13 --tmux pi-i-13 --cwd ../wt-13 --root . \
  --context-file /tmp/task-13.md --auto-stop
harnex run pi --id pi-i-14 --tmux pi-i-14 --cwd ../wt-14 --root . \
  --context-file /tmp/task-14.md --auto-stop
```

Watch each with `harnex watch --id`, or, from a Claude Code or Pi
supervisor, wait for every lane you launched in one call:

```bash
harnex watch --owner --until-idle --timeout 90m
```

A Claude Code subagent shares its parent's session ID; it passes the
same `--owner-tag TAG` to `harnex run` and `harnex watch --owner` so
it sees only its own lanes (`harnex agents-guide claude`).

## Sending work and waiting for it to finish

Use `--wait-for-idle` to block until the agent finishes
processing:

```bash
harnex send --id pi-i-13 --message "implement the plan" --wait-for-idle --timeout 600
```

This is better than separate send + wait commands because there's
no gap where you might check too early and think the agent is
done when it hasn't started yet.

With Pi, `--wait-done` goes further: it blocks until the turn the
message started (or joined) settles and prints that turn's result,
with the same exit codes as `harnex wait --until done`:

```bash
harnex send --id pi-i-13 --message "Also cover the empty-input case." --wait-done --timeout 540
```

Treat `--wait-for-idle` as the fence, not the report. After the
send returns, use `harnex pane` or `harnex logs` to inspect what
actually happened.

## Sending large prompts

Shell quoting and terminal input don't love multi-kilobyte inline
messages. For anything longer than a few sentences, write the
task to a file and tell the agent to read it:

```bash
cat > /tmp/task-impl-13.md <<'EOF'
Implement phase 2 from koder/plans/03_output_streaming.md.

Focus on:
- The HTTP endpoint for streaming output
- Integration with the existing ring buffer
- Tests for the new endpoint

Do not modify the CLI commands.
EOF

harnex send --id pi-i-13 --message "Read and execute /tmp/task-impl-13.md"
```

If the task is already written down — a plan file, an issue, a
spec — just point to it:

```bash
harnex send --id pi-i-13 --message "Implement koder/plans/plan_09_atomic_send_wait.md"
```

At launch, `--context-file` sends a file's text itself as the task,
and `--context-section` sends only the part under one heading:

```bash
harnex run pi --id pi-i-13 --tmux pi-i-13 \
  --context-file koder/briefs/13.md --context-section "## Task" --auto-stop
```

This is more reliable, easier to debug (you can read the file to
see exactly what was sent), and avoids quoting headaches.

## Capturing results

For dependable multi-step work, prefer file handoffs over reply
messages.

Examples:

```bash
# Planning
harnex send --id pi-p-13 --message "Read koder/issues/13_atomic_send_wait.md and write a plan to /tmp/plan-13.md. Do not change code." --wait-for-idle --timeout 600

# Review
harnex send --id cl-r-13 --message "Review the current changes against /tmp/plan-13.md and write findings to /tmp/review-13.md. If clean, say so explicitly." --wait-for-idle --timeout 600
```

Why files work better:

- The next worker can read exactly the same artifact you reviewed
- The supervisor can inspect the artifact without scraping terminal text
- If the session dies, the output still exists

Pi results also carry the worker's last reply as `final_message` (in
`run --wait-done`, `send --wait-done`, and `watch --owner` output).
That is enough for a short answer; use a file for anything the next
step must read.

After the worker finishes, inspect the screen:

```bash
harnex pane --id cl-r-13 --lines 60
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
harnex stop --id pi-i-13
```

For Pi, harnex aborts any running turn and ends the `pi --mode rpc`
process. PTY agents get their native exit sequence (e.g. `/exit` for
Claude). Either way the agent shuts down cleanly.

## A reliable supervised workflow

Use fresh instances for each stage. Pi plans, implements, and fixes.
Claude (or a fresh Pi lane) only reviews.

```bash
# 1. Plan with Pi
harnex run pi --id pi-p-13 --tmux pi-p-13
harnex send --id pi-p-13 --message "Read koder/issues/13_atomic_send_wait.md and write a concrete implementation plan to /tmp/plan-13.md. Do not change code." --wait-for-idle --timeout 600
harnex pane --id pi-p-13 --lines 60
harnex stop --id pi-p-13

# 2. Implement with a fresh Pi
harnex run pi --id pi-i-13 --tmux pi-i-13
harnex send --id pi-i-13 --message "Read /tmp/plan-13.md, implement it, run tests, and write a short summary to /tmp/impl-13.md." --wait-for-idle --timeout 1200
harnex pane --id pi-i-13 --lines 80
harnex stop --id pi-i-13

# 3. Review with a fresh Claude
harnex run claude --id cl-r-13 --tmux cl-r-13
harnex send --id cl-r-13 --message "Review the current changes against /tmp/plan-13.md. Write findings to /tmp/review-13.md. If there are no issues, say clean." --wait-for-idle --timeout 900
harnex pane --id cl-r-13 --lines 80
harnex stop --id cl-r-13
```

If the review finds issues, spawn a fresh Pi fixer (`pi-f-13`) and
tell it to read `/tmp/review-13.md`, fix the findings, run tests, and
write an updated summary. Then review again with a fresh Claude
instance, or a fresh Pi lane (`pi-r-13`) that has not seen the
implementation.

Each Pi step can also be one blocking call:
`harnex run pi --id pi-p-13 --tmux pi-p-13 --context "..." --auto-stop --wait-done --wait-timeout 9m`.

## Teaching agents about harnex

Harnex ships its agent guidance in the CLI. No skill install or
project-local docs are required:

```bash
harnex agents-guide             # list all agent guide topics
harnex agents-guide dispatch    # Fire and Watch lifecycle
harnex agents-guide monitoring  # completion signals and polling
harnex agents-guide naming      # session IDs and artifact names
harnex agents-guide claude      # Pi workers as tools from Claude Code
```

Tell an agent to run `harnex --help` and then `harnex agents-guide`.
The guides cover dispatch, chain implementation, buddies, monitoring,
naming conventions, and Claude Code using Pi workers as tools.

## Recipes

Tested workflows for common multi-agent patterns. Read them
from the CLI:

```bash
harnex recipes             # list all recipes
harnex recipes show 01     # read one
harnex agents-guide        # deeper agent-facing guidance
```

- **Fire and Watch** (`harnex recipes show 01`) — send work to a
  fresh worker, watch its tmux screen, capture the result, stop it.
- **Chain Implement** (`harnex recipes show 02`) — process a
  batch as repeated fire-and-watch: Pi plan/implement, Claude (or a
  fresh Pi lane) review, Pi fix, then review again if needed.
- **Buddy** (`harnex recipes show 03`) — spawn an accountability
  partner for overnight or long-running work. The buddy polls the
  worker's screen and nudges it if it stalls.

## What's next

For the full command reference, flags, HTTP API, and internals,
see [TECHNICAL.md](TECHNICAL.md). The packaged
[dispatch telemetry](docs/dispatch-telemetry.md) and
[configuration](docs/configuration.md) references cover the canonical v2 stream,
phase allowlists, and log retention.
