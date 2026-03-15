# Issue 01: Clean Stop Primitive

**Status**: fixed
**Priority**: P1
**Created**: 2026-03-14

## Problem

An external caller needed a clean way to tell a harnex-managed session to
finish and exit without killing the PID directly.

That supervisor workflow is:

1. Spawn a worker
2. Send work
3. Wait until the worker returns to prompt
4. Inspect results
5. Stop the worker cleanly
6. Wait for actual exit

Without a stop primitive, step 5 required either relying on the wrapped agent
to self-exit or sending a raw process kill, which skipped the normal control
path and made cleanup less predictable.

## Resolution

This shipped as `harnex stop --id <ID>` plus `POST /stop` on the session API.

Implemented pieces:

- `lib/harnex/commands/stop.rb` resolves the target session and calls `/stop`
- `lib/harnex/runtime/api_server.rb` exposes `POST /stop`
- `lib/harnex/runtime/session.rb` implements `Session#inject_stop`
- adapters own the stop sequence via `inject_exit(writer)`

API response:

```json
{"ok":true,"signal":"exit_sequence_sent"}
```

## Result

The clean lifecycle is now:

```bash
harnex send --id worker --message "implement phase 1"
harnex wait --id worker --until prompt
harnex stop --id worker
harnex wait --id worker
```
