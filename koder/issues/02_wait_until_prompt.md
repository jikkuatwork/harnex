# Issue 02: Wait-Until-Prompt Mode

**Status**: open
**Priority**: P1
**Created**: 2026-03-14

## Problem

`harnex wait` only blocks until a session **exits**. There is no way to block
until a session returns to **prompt** (meaning: the agent finished its current
task and is idle, ready for the next message).

This forces workflows into one of two patterns:
1. One-shot workers: spawn → work → exit → wait. Requires a new session per phase.
2. Polling: loop `harnex send --id X --status` checking for `prompt` state.

Neither is great. One-shot wastes startup time. Polling is ugly and races.

## Proposal

### `harnex wait --id <ID> --until prompt`

Blocks until the session's state machine transitions to `prompt`.

Mechanics:
- Connect to session's HTTP API
- Poll `/status` at reasonable interval (500ms–1s)
- Return when `agent_state == "prompt"`
- Timeout via `--timeout SECS` (default: no timeout? or 3600?)

Return value (JSON):
```json
{
  "id": "worker",
  "state": "prompt",
  "waited_seconds": 45.2
}
```

### Why this matters

This is the missing primitive for multi-phase workflows where a supervisor
reuses a session:

```bash
harnex run codex --id worker --tmux cx-w1
harnex send --id worker --message "implement plan 150"
harnex wait --id worker --until prompt    # blocks until codex finishes
# supervisor inspects working tree, decides next action
harnex send --id worker --message "now fix these issues: ..."
harnex wait --id worker --until prompt
harnex exit --id worker
harnex wait --id worker                   # blocks until actual exit
```

Without this, the supervisor must either poll or use one-shot sessions.

### Alternative considered

Could use `harnex send --async` and then poll `/messages/:id` for delivery +
completion. But that only tells you the message was delivered, not that the
agent finished processing it.

## Interaction with Issue 01

Together with `harnex exit`, this gives the full lifecycle:
```
spawn → send → wait-until-prompt → (inspect/decide) → exit → wait-for-exit
```
