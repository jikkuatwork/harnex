# Issue 02: Wait-Until-Prompt Mode

**Status**: fixed
**Priority**: P1
**Created**: 2026-03-14

## Problem

`harnex wait` originally only handled session exit. There was no clean way to
block until a reused worker became idle again and was ready for the next
message.

That forced orchestration into either:

1. One-shot workers: spawn, do work, exit
2. Polling: repeatedly query status until the session looked idle

Both patterns were worse than a first-class "wait until prompt" primitive.

## Resolution

This shipped as `harnex wait --id <ID> --until prompt`.

Implementation notes:

- `lib/harnex/commands/wait.rb` reads the session registry once, then polls the
  local `/status` endpoint
- readiness is based on `agent_state`, not just raw prompt text
- `--timeout SECS` returns exit code `124` and a JSON timeout payload

Success response shape:

```json
{"ok":true,"id":"worker","state":"prompt","waited_seconds":45.2}
```

## Why it mattered

This is the reuse primitive for multi-phase workflows:

```bash
harnex send --id worker --message "implement phase 1"
harnex wait --id worker --until prompt
harnex send --id worker --message "now fix these review findings"
harnex wait --id worker --until prompt
harnex stop --id worker
harnex wait --id worker
```

Together with Issue 01, harnex now supports the full
`send -> wait for prompt -> inspect -> stop -> wait for exit` loop.
