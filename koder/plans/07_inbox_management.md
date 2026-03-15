# Plan 07: Inbox Management

Layer: A (multi-agent reliability)
Issue: #10
Date: 2026-03-15

## ONE THING

Add TTL expiry and inspection to the inbox so stale messages don't
silently accumulate.

## Problem

When a queued message can't deliver (adapter stuck in `unknown`, session
unresponsive), it sits in the inbox forever. If the sender retries with
`--force`, the original stale message is still pending. When the session
eventually recovers, it gets both — the stale message first, then the
force-sent duplicate, in the wrong order.

## Fix — two phases

### Phase 1: TTL auto-expiry (priority)

Add a configurable TTL to inbox messages. Messages older than TTL are
discarded from the queue during the delivery loop.

**`lib/harnex/runtime/inbox.rb`**:

```ruby
DEFAULT_TTL = 120  # seconds

def initialize(session, state_machine, ttl: DEFAULT_TTL)
  # ...existing...
  @ttl = ttl
  @expired_total = 0
end
```

In `delivery_loop`, before attempting delivery on the front message:

```ruby
def expire_stale_messages
  now = Time.now
  @mutex.synchronize do
    while (msg = @queue.first) && (now - msg.queued_at) > @ttl
      msg.status = :expired
      @queue.shift
      @expired_total += 1
    end
  end
end
```

Add `expired_total` to `stats`.

**`lib/harnex/commands/run.rb`** — add `--inbox-ttl SECS` option,
passed through to `Session` → `Inbox`. Environment fallback:
`HARNEX_INBOX_TTL`.

### Phase 2: API inspection and drop endpoints

Add to `ApiServer`:

- `GET /inbox` — list pending messages (id, queued_at, text preview,
  status)
- `DELETE /inbox/:id` — drop a specific message
- `DELETE /inbox` — clear all pending messages

**`lib/harnex/runtime/inbox.rb`** — add public methods:

```ruby
def pending_messages
  @mutex.synchronize { @queue.map(&:to_h) }
end

def drop(message_id)
  @mutex.synchronize do
    msg = @messages[message_id]
    return nil unless msg
    @queue.delete_if { |m| m.id == message_id }
    msg.status = :dropped
    msg.to_h
  end
end

def clear
  @mutex.synchronize do
    count = @queue.size
    @queue.each { |m| m.status = :dropped }
    @queue.clear
    count
  end
end
```

**`lib/harnex/runtime/api_server.rb`** — route the three new endpoints.

No new CLI command — use `curl` or `harnex status --json` for now.
A `harnex inbox` CLI command is deferred.

### Structural changes

| File | Change |
|---|---|
| `lib/harnex/runtime/inbox.rb` | TTL, expiry, pending/drop/clear |
| `lib/harnex/runtime/api_server.rb` | 3 new routes |
| `lib/harnex/commands/run.rb` | `--inbox-ttl` option |
| `lib/harnex/runtime/session.rb` | Pass ttl to Inbox constructor |

### Tests

- Inbox with TTL=0.1: enqueue, sleep 0.2, verify message expired
- Inbox drop: enqueue, drop by id, verify removed from queue
- Inbox clear: enqueue 3, clear, verify empty
- Stats include expired_total
- API endpoint tests for GET/DELETE /inbox

## Acceptance criteria

- [ ] Messages older than TTL are auto-expired
- [ ] `stats` reports `expired_total`
- [ ] `--inbox-ttl` configures TTL per session
- [ ] API: `GET /inbox` lists pending messages
- [ ] API: `DELETE /inbox/:id` drops a message
- [ ] API: `DELETE /inbox` clears all
- [ ] Tests pass

## Deferral list

- `harnex inbox` CLI command (use curl for now)
- Per-message TTL override
- Expired message callback/notification
- Inbox size limit changes (currently MAX_PENDING=64, fine)
