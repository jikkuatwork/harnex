# Recipe: Fire and Watch

Harnex wraps terminal AI agents and lets them find and message
each other. `harnex pane` reads a worker's tmux screen directly.

Fire and watch: send a task to a worker, then periodically read
its screen until it's back at a prompt.

## Steps

### 1. Spawn the worker

```bash
harnex run codex --id cx-23 --tmux
```

### 2. Send the task

If the plan file is self-contained, reference it directly:

```bash
harnex send --id cx-23 --message "Implement koder/plans/plan_23.md. Run tests when done."
```

For tasks that need extra context, write a temp file first:

```bash
cat > /tmp/task-cx-23.md <<'EOF'
Implement koder/plans/plan_23.md.
Run the full test suite when done.
When finished: harnex send --id <your-id> --message "done: <summary>"
EOF

harnex send --id cx-23 --message "Read and execute /tmp/task-cx-23.md"
```

### 3. Watch until done

Wait ~30 seconds, then read the worker's screen:

```bash
harnex pane --id cx-23 --lines 25
```

If the worker is still going, wait and check again. Adjust the
interval to the task — 30s for typical work, shorter for quick
fixes, longer for builds.

When the worker looks idle, capture a larger snapshot:

```bash
harnex pane --id cx-23 --lines 80
```

### 5. Stop or reuse

```bash
harnex stop --id cx-23
```

Or send the next task to the same worker.

## Rationale

Sending work to an agent is reliable. Getting a structured
response back is not — agents forget reply instructions, the
loopback message fails to deliver, or the format is wrong.
Reading the tmux screen with `harnex pane` bypasses all of that.
It works the same way a human watching the terminal would — no
cooperation from the worker needed. The send-back instruction in
the task prompt is cheap insurance: if the worker follows it, you
get a bonus summary; if not, the pane capture has everything.
