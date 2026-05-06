---
id: 15
title: "Auto-stop session when wrapped agent returns to prompt after task completion"
status: fixed
priority: P2
created: 2026-03-22
---

# Issue 15: Auto-Stop Session When Agent Completes Task

## Problem

When a harnex session is launched with `--context` (a one-shot task), the wrapped
agent completes the task, commits, and returns to its prompt — but the session
stays alive indefinitely. The tmux window remains open, the registry entry
persists, and the HTTP API keeps running.

This forces the orchestrator to manually poll with `harnex pane`, notice the
agent is back at its prompt, and then run `harnex stop`. For fire-and-watch
workflows where the task is self-contained (e.g. "implement this issue and
commit"), there's no reason to keep the session alive after the agent finishes.

### Observed behavior

```
# Launch one-shot task
harnex run codex --id cx-plan-26 --tmux cx-plan-26 \
  --context "Implement koder/issues/26. Commit when done."

# Codex finishes, commits, returns to prompt
# Session stays alive — tmux window open, registry active
# Orchestrator must manually: harnex stop --id cx-plan-26
```

### Expected behavior

For one-shot tasks, harnex should optionally detect that the agent has returned
to its prompt after processing the initial context, and automatically stop the
session.

## Proposal

Add `--auto-stop` flag to `harnex run`. When set:

1. After delivering the `--context` message, wait for the agent to go
   busy → prompt (same transition `--wait-for-idle` detects).
2. Once the agent returns to prompt, send the adapter's exit sequence
   (same as `harnex stop`).
3. Write the exit record as normal.

This should only activate when `--context` is also provided — it makes no sense
for interactive sessions.

## Alternatives considered

- **Timeout-based auto-stop**: kill after N minutes idle. Simpler but less
  precise — agent might be idle mid-task (waiting for a slow build).
- **Always auto-stop with `--context`**: too aggressive. Some workflows send
  an initial context but follow up with additional `harnex send` messages.
- **Orchestrator-side wrapper**: the orchestrator could `harnex send --wait-for-idle`
  then `harnex stop`. Works today but adds boilerplate to every dispatch.

## Notes

- `--auto-stop` without `--context` should be rejected with a clear error.
- If `--auto-stop` and `--wait-for-idle` are both set on a `send`, they serve
  different purposes — `--auto-stop` is session lifecycle, `--wait-for-idle` is
  message lifecycle.
