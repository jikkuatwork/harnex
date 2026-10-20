# Recipe: Fire and Watch

This is the core harnex recipe.

Spawn a fresh worker, send it one task, watch its screen until it
is done, capture the result, stop it. Compose bigger workflows by
repeating this pattern with file handoffs between steps.

## Steps

### 1. Spawn the worker

```bash
harnex run pi --id pi-i-23 --tmux pi-i-23
```

### 2. Send the task

If the plan file is self-contained, reference it directly:

```bash
harnex send --id pi-i-23 --message "Implement koder/plans/plan_23.md. Run tests when done."
harnex wait --id pi-i-23 --until done --timeout 1200
```

For tasks that need structured output, tell the worker to write a
file and inspect the screen separately:

```bash
cat > /tmp/task-impl-23.md <<'EOF'
Implement koder/plans/plan_23.md.
Run the full test suite when done.
Write a short summary to /tmp/impl-23.md.
EOF

harnex send --id pi-i-23 --message "Read and execute /tmp/task-impl-23.md"
harnex wait --id pi-i-23 --until done --timeout 1200
```

### 3. Watch until done

Use `harnex wait --until done` as the work-level fence, then read the worker's screen:

```bash
harnex pane --id pi-i-23 --lines 25
```

If you prefer to watch while it runs:

```bash
harnex pane --id pi-i-23 --follow
```

When the worker looks idle, capture a larger snapshot:

```bash
harnex pane --id pi-i-23 --lines 80
```

### 4. Stop the worker

```bash
harnex stop --id pi-i-23
```

Start a fresh worker for the next step instead of reusing this one.

## Common step types

Use the same pattern for every role:

- Pi planning: "Write the plan to `/tmp/plan-23.md`. Do not change code."
- Pi implementation: "Read `/tmp/plan-23.md`, implement it, run tests, write `/tmp/impl-23.md`."
- Claude (or fresh Pi) review: "Review current changes against `/tmp/plan-23.md` and write findings to `/tmp/review-23.md`."
- Pi fix: "Read `/tmp/review-23.md`, fix the issues, run tests, write `/tmp/fix-23.md`."

## Rationale

This is the dependable path because it minimizes the fragile parts:

- Fresh worker per step avoids context bleed and stale inbox state
- File artifacts are easier to pass between steps than callback messages
- `harnex pane` shows the truth even when the worker ignores reply instructions
- Stopping the worker after each step keeps the workflow disposable
