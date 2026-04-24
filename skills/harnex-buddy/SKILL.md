---
name: harnex-buddy
description: Spawn an accountability partner for long-running harnex sessions. Use when the user asks to run something overnight, unattended, or for any work expected to take more than 30 minutes without supervision.
---

# Buddy — Accountability Partner for Long-Running Work

For any long-running or unattended work, spawn a **buddy** — a second harnex
agent that watches the worker and nudges it if it stalls.

The buddy is an LLM, so it has intelligence for free. It reads the worker's
screen, reasons about whether it's stuck, and composes a meaningful nudge.

Dispatch workers via `harnex-dispatch` first. This skill owns only buddy
behavior after the worker is already running.

## When to activate

- User says "do this overnight" or "run this while I'm away"
- Task is expected to take more than 30 minutes unattended
- User explicitly asks for a buddy, accountability partner, or monitoring
- User asks to "keep an eye on" a dispatched worker

## Spawn the buddy

After dispatching the worker with `harnex-dispatch`, spawn a buddy alongside
it. Keep ID/tmux naming consistent with `harnex-dispatch` (`--tmux` matches
`--id`):

```bash
# Spawn its buddy
harnex run claude --id buddy-42 --tmux buddy-42
```

## Write the buddy prompt

Write a task file with the watching instructions, then send it:

```bash
cat > /tmp/buddy-42.md <<'EOF'
You are an accountability partner for harnex session `cx-impl-42`.

Your job:
1. Every 5 minutes, check on the worker:
   - `harnex pane --id cx-impl-42 --lines 20`
   - `harnex status --id cx-impl-42 --json`
2. If the worker appears stuck at a prompt for more than 10 minutes
   with no progress, nudge it:
   - `harnex send --id cx-impl-42 --message "You appear to have stalled. Continue with your current task."`
3. If the worker has exited, report back to the invoker:
   - `tmux send-keys -t "$HARNEX_SPAWNER_PANE" "cx-impl-42 has exited. Check results." Enter`
4. Keep watching until the worker finishes or is stopped.

Do not interfere with work in progress. Only nudge when clearly stalled.
EOF

harnex send --id buddy-42 --message "Read and execute /tmp/buddy-42.md"
```

Adjust the polling interval (5 min), stall threshold (10 min), and nudge
message to match the workload.

## Return channel

The buddy can reach back to the invoker (your raw Claude session) via
`$HARNEX_SPAWNER_PANE` — the stable tmux pane ID set automatically by
harnex at spawn time:

```bash
# Read the invoker's screen
tmux capture-pane -t "$HARNEX_SPAWNER_PANE" -p

# Type into the invoker
tmux send-keys -t "$HARNEX_SPAWNER_PANE" "worker-42 finished" Enter
```

The invoker does NOT need to be a harnex session. It just needs to be in tmux.

## Naming convention

Use naming from `harnex-dispatch`: set `--tmux <same-as-id>` for every
session and keep the buddy ID paired with the worker step ID.

## Cleanup

Stop the buddy after the worker finishes:

```bash
harnex stop --id buddy-42
```

## Notes

- For chain orchestration, phase gates, and the 5-concurrent parallel planning
  cap, see `harnex-chain`.
- One buddy per worker, or one buddy watching multiple sessions
- The buddy is a regular harnex session — stop, inspect, log it like any other
- Tune polling and thresholds in the buddy's prompt, not in harnex config
- See `recipes/03_buddy.md` for the full recipe
