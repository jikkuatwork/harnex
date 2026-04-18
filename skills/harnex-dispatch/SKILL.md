---
name: harnex-dispatch
description: Fire & Watch — the standard pattern for launching and monitoring harnex agent sessions. Use when dispatching implementation, review, or fix agents.
---

# Dispatch — Fire & Watch

Every harnex agent dispatch follows three phases: **spawn**, **watch**, **stop**.

## 1. Spawn

Launch the agent in a tmux window so the user can observe it live:

```bash
harnex run codex --id cx-impl-NN --tmux cx-impl-NN \
  --context "Implement koder/plans/NN_name.md. Run tests when done. Commit after each phase."
```

For reviews (Claude):

```bash
harnex run claude --id cl-rev-NN --tmux cl-rev-NN \
  --context "Review the implementation of plan NN against the spec in koder/plans/NN_name.md. Write findings to koder/reviews/NN_name.md"
```

For complex task prompts, write to a temp file and reference it:

```bash
cat > /tmp/task-impl-NN.md <<'EOF'
Detailed instructions here...
EOF

harnex run codex --id cx-impl-NN --tmux cx-impl-NN \
  --context "Read and execute /tmp/task-impl-NN.md"
```

## 2. Watch

Poll the agent's screen with `harnex pane`. Checking is cheap — a 20-line
tail is a few hundred bytes.

**Default: poll every 30 seconds.** This is fine for most work. The check
itself costs almost nothing and catches completion quickly.

**Progressive intervals** when you expect longer work:

| Elapsed | Interval | Rationale |
|---------|----------|-----------|
| 0–2 min | 30s | Catch fast completions and early errors |
| 2–10 min | 60s | Steady state for typical implementations |
| 10+ min | 120s | Long-running work, reduce noise |

```bash
# Quick check — last 20 lines is enough to see if done or stuck
harnex pane --id cx-impl-NN --lines 20

# JSON metadata (includes capture timestamp)
harnex pane --id cx-impl-NN --lines 20 --json
```

When checking, look for:
- **At prompt** → agent finished, read last output for results
- **Still working** → agent is reading files, running tests, editing code
- **Error/stuck** → agent hit a blocker, may need intervention
- **Permission prompt** → agent waiting for user approval, intervene

### Background poll from Claude Code

```bash
# Run as a background task, check result when notified
harnex pane --id cx-impl-NN --lines 20
```

Or use `--follow` for continuous monitoring:

```bash
harnex pane --id cx-impl-NN --lines 20 --follow
```

## 3. Stop

When the agent is done (at prompt, work committed):

```bash
harnex stop --id cx-impl-NN
```

Always verify the agent's work landed before stopping:

```bash
# Quick sanity check
harnex pane --id cx-impl-NN --lines 20
# Confirm commits exist
git log --oneline -5
# Then stop
harnex stop --id cx-impl-NN
```

## Naming Conventions

| Step | ID pattern | tmux window | Example |
|------|-----------|-------------|---------|
| Implement | `cx-impl-NN` | `cx-impl-NN` | `cx-impl-42` |
| Review | `cl-rev-NN` | `cl-rev-NN` | `cl-rev-42` |
| Fix | `cx-fix-NN` | `cx-fix-NN` | `cx-fix-42` |
| Plan write | `cx-plan-NN` | `cx-plan-NN` | `cx-plan-42` |
| Plan fix | `cx-fix-plan-NN` | `cx-fix-plan-NN` | `cx-fix-plan-42` |

**Rule**: Always use `--tmux <same-as-id>` so the tmux window name matches
the session ID. Never use a different tmux name.

## Full Dispatch Lifecycle

```
1. Mark plan IN_PROGRESS, commit
2. harnex run codex --id cx-impl-NN --tmux cx-impl-NN
3. Poll with harnex pane --lines 20 every 30s
4. When done: verify commits, harnex stop
5. harnex run claude --id cl-rev-NN --tmux cl-rev-NN (review)
6. Poll with harnex pane --lines 20 every 30s
7. When done: harnex stop, read review
8. If NEEDS FIXES: harnex run codex --id cx-fix-NN (fix pass)
9. If PASS: done
```

## Worktree Option

Use worktrees only when you need **parallel isolation** — e.g., implementing
one plan while another is being reviewed, or when the user explicitly asks.
Do not default to worktrees for serial work.

### Worktree Setup

```bash
# Commit all files the agent will need BEFORE creating the worktree
# (untracked files don't carry over)
git add koder/plans/NN_name.md
git commit -m "docs(plan-NN): add plan"

# Create worktree
WORKTREE="$(pwd)/../$(basename $(pwd))-plan-NN"
git worktree add ${WORKTREE} -b plan/NN_name master

# Launch from worktree
cd ${WORKTREE}
harnex run codex --id cx-impl-NN --tmux cx-impl-NN \
  --context "Implement koder/plans/NN_name.md. Run tests when done."
```

### Worktree Caveats

- **cd first**: launch and manage sessions from the worktree directory
- **Merge conflicts**: `koder/` state files may diverge — on merge, keep
  master's versions of session-state files
- **Cleanup**: `git worktree remove <path>` then `git branch -d plan/<branch>`

## Checking Status

```bash
harnex status           # current repo sessions
harnex status --all     # all repos
```

## Buddy for Long-Running Dispatches

If the dispatched work is expected to take a long time (overnight, multi-hour)
or the user asks for unattended execution, spawn a buddy alongside the worker:

```bash
# Worker
harnex run codex --id cx-impl-NN --tmux cx-impl-NN \
  --context "Implement koder/plans/NN_name.md. Run tests when done."

# Buddy to watch it
harnex run claude --id buddy-NN --tmux buddy-NN
harnex send --id buddy-NN --message "Watch session cx-impl-NN. Poll every 5 min with harnex pane --id cx-impl-NN --lines 20. Nudge with harnex send if stuck for >10 min. Report back to \$HARNEX_SPAWNER_PANE when done."
```

The buddy replaces manual Fire & Watch polling. See `recipes/03_buddy.md`.

## What NOT to Do

- **Never** launch agents with raw `tmux send-keys` or `tmux new-window`
- **Never** use `--tmux NAME` where NAME differs from `--id`
- **Never** pass `-- --cd <path>` to Claude sessions (unsupported flag)
- **Never** poll with raw `tmux capture-pane` — use `harnex pane`
- **Never** rely on `--wait-for-idle` alone — always use Fire & Watch
- **Never** use `c-zai-dangerous` or direct CLI spawning outside harnex
