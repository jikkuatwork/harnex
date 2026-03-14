# Issue 01: Clean Exit Primitive

**Status**: fixed
**Priority**: P1
**Created**: 2026-03-14

## Problem

There is no way for an external caller to gracefully terminate a harnex session.

When a supervisor spawns a worker via `harnex run --detach` or `--tmux`, the
worker runs until the human or the agent itself decides to quit. The supervisor
has no CLI command to say "you're done, exit cleanly."

This blocks the supervisor pattern for orchestration workflows where:
1. Supervisor spawns worker, sends task, waits for prompt (task complete)
2. Supervisor reads results from working tree / result files
3. Supervisor signals worker to exit
4. Supervisor moves to next phase

Today step 3 requires either:
- Hoping the prompt instructs the agent to self-exit (unreliable)
- `kill` on the PID (unclean — no exit status file, no cleanup)

## Proposal

### `harnex exit --id <ID>`

Sends the adapter-appropriate exit sequence to the session's PTY:
- Codex: `/exit\n`
- Claude: `/exit\n`

Mechanics:
- Resolve session from registry (same as `harnex send`)
- Call adapter method `exit_sequence()` → returns the keystrokes to send
- Write sequence to PTY (bypasses inbox — this is a control action, not a message)
- Return immediately (caller uses `harnex wait` to block on actual exit)

### API surface

```
POST /exit
Authorization: Bearer <token>

Response: 200 {"ok": true, "signal": "exit_sequence_sent"}
```

### Adapter contract addition

```ruby
# Base adapter — subclasses override
def exit_sequence
  "/exit\n"  # default, works for both codex and claude today
end
```

## Related

This also improves the `harnex wait` story. A supervisor can now do:
```bash
harnex exit --id worker
harnex wait --id worker --timeout 10
```

Which is a clean "finish and confirm" pattern.
