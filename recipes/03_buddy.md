# Recipe: Buddy

Spawn an accountability partner for a long-running session.

The buddy is a separate harnex agent whose only job is to periodically
check on the worker and nudge it if it stalls. The buddy is an LLM, so
it has intelligence for free — it can read the worker's screen, reason
about whether it's stuck, and compose a meaningful nudge.

No special monitoring code, no configuration. Just another harnex
session using existing primitives.

## When to use

- Overnight or multi-hour pipelines
- Any work where you won't be watching and want recovery from stalls
- When the invoking agent (you) dispatches a worker and wants assurance
  it won't die silently

## Steps

### 1. Spawn the worker

```bash
harnex run codex --id worker-42 --tmux worker-42
harnex send --id worker-42 --message "Read and execute /tmp/task-42.md"
```

### 2. Spawn its buddy

```bash
harnex run claude --id buddy-42 --tmux buddy-42
```

### 3. Give the buddy its instructions

```bash
cat > /tmp/buddy-42.md <<'EOF'
You are an accountability partner for harnex session `worker-42`.

Your job:
1. Every 5 minutes, check on the worker:
   - `harnex pane --id worker-42 --lines 30`
   - `harnex status --id worker-42 --json`
2. If the worker appears stuck at a prompt for more than 10 minutes
   with no progress, nudge it:
   - `harnex send --id worker-42 --message "You appear to have stalled. Continue with your current task."`
3. If the worker has exited (status shows no session), report back:
   - `tmux send-keys -t "$HARNEX_SPAWNER_PANE" "worker-42 has exited. Check results." Enter`
4. Keep watching until the worker finishes or is stopped.

Do not interfere with work in progress. Only nudge when clearly stalled.
EOF

harnex send --id buddy-42 --message "Read and execute /tmp/buddy-42.md"
```

## Return channel

The buddy can reach its invoker (your raw Claude session) via
`$HARNEX_SPAWNER_PANE` — the tmux pane ID of whoever ran `harnex run`.
This works even if the invoker is not a harnex session:

```bash
# Buddy reads the invoker's screen
tmux capture-pane -t "$HARNEX_SPAWNER_PANE" -p

# Buddy types into the invoker
tmux send-keys -t "$HARNEX_SPAWNER_PANE" "worker-42 finished, all tests pass" Enter
```

## Naming convention

| Role | ID pattern | Example |
|------|-----------|---------|
| Worker | `worker-NN` | `worker-42` |
| Buddy | `buddy-NN` | `buddy-42` |

Match the buddy ID to the worker it watches.

## Cleanup

Stop the buddy after the worker finishes:

```bash
harnex stop --id buddy-42
```

Or tell the buddy to self-stop in its instructions: "When the worker
exits, run `harnex stop --id buddy-42` on yourself."

## Notes

- The buddy is a regular harnex session. Inspect it with `harnex pane`,
  stop it with `harnex stop`, check it with `harnex status`.
- For multiple workers, spawn one buddy per worker or one buddy that
  watches several sessions.
- The buddy's intelligence comes from being an LLM. It doesn't
  pattern-match — it reads the screen and reasons about what to do.
- Tune the polling interval and stall threshold in the buddy's prompt,
  not in harnex configuration.
