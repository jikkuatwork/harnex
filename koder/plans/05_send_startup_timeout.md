# Plan 05: Fix Send-to-Fresh-Session Timeout

Layer: A (multi-agent reliability)
Issue: #08
Date: 2026-03-15

## ONE THING

Make `harnex send` reliably deliver to sessions that haven't reached
their first prompt yet.

## Problem

`Inbox#delivery_loop` calls `@state_machine.wait_for_prompt(300)` but
the caller's `--timeout` (default 30s) expires first. The message gets
HTTP 202 (queued), then the sender's poll loop times out waiting for
delivery confirmation. The message eventually delivers when the agent
reaches prompt, but the caller already got a timeout error.

This is a UX problem, not a delivery problem. The inbox does the right
thing — the caller just gives up too early.

## Fix

Two changes, both in `lib/harnex/commands/send.rb`:

### 1. Longer default timeout for delivery polling

The send command's delivery poll timeout should default to 120s instead
of 30s. Fresh agent startups in large repos routinely take 30-60s.

**`lib/harnex/commands/send.rb`** — change:
```ruby
DEFAULT_TIMEOUT = 120.0  # was 30.0
```

### 2. Early return on queue acceptance with `--no-wait`

Already exists. Document it more prominently in `--help` output as the
recommended approach for automated workflows:

```
--no-wait   Return immediately after queueing (HTTP 202). Use for
            fire-and-forget or when polling delivery separately.
```

### Structural changes

**`lib/harnex/commands/send.rb`**:
- Change `DEFAULT_TIMEOUT` from 30.0 to 120.0
- Update help text for `--no-wait`

### Tests

- Update any test that asserts the old default timeout value
- Add test: send with `--timeout 1` to a non-prompt session returns
  timeout error (existing behavior, just verify)

## Acceptance criteria

- [ ] `harnex send` default timeout is 120s
- [ ] `harnex send --no-wait` returns immediately with message_id
- [ ] Help text documents `--no-wait` as recommended for automation
- [ ] Tests pass

## Deferral list

- Adaptive timeout based on session age (fresh vs established)
- Server-sent events for delivery notification
- Separate `harnex message status --id <msg_id>` command
