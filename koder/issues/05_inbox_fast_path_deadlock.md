# 05 — Inbox fast-path deadlock

**Priority:** P1
**Status:** open
**Found:** 2026-03-14

## Description

In `Inbox#enqueue`, the fast-path optimization (line ~758-764 of
`lib/harnex.rb`) calls `deliver_now` while already holding `@mutex`. But
`deliver_now` also acquires `@mutex` at line ~802, causing a recursive
locking `ThreadError`.

```ruby
# enqueue (simplified)
@mutex.synchronize do              # <-- acquires @mutex
  if @queue.empty? && @state_machine.state == :prompt
    result = deliver_now(msg)      # <-- calls @mutex.synchronize again → deadlock
  end
end
```

## Impact

The fast-path never works. In practice this is masked because:
- Force messages bypass the fast path entirely
- The delivery thread handles non-force messages
- The ThreadError is not caught, so it propagates and the message
  falls through to the queue path (which works correctly via the thread)

Actually, re-reading the code: the error propagates out of `enqueue` uncaught,
so callers would see a `ThreadError`. This likely means the fast-path is dead
code that was never exercised in production — all real sends go through the
delivery thread or force path.

## Fix

Move the mutex acquisition in `deliver_now` so it doesn't conflict with the
caller's lock, or restructure `enqueue` to release the mutex before calling
`deliver_now` on the fast path. Simplest fix: extract the bookkeeping from
`deliver_now` into a separate method that assumes the caller already holds the
lock.
