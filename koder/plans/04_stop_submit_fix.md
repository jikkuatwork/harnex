# Plan 04: Fix `harnex stop` Submit Delivery

Layer: A (multi-agent reliability)
Issue: #07
Date: 2026-03-15

## ONE THING

Make `inject_exit` deliver the exit command AND submit it reliably.

## Problem

`Base#inject_exit` writes `/exit` + `\r` as two immediate `writer.write`
calls with no delay. The Claude and Codex `build_send_payload` methods
already solve this for regular messages: they use a `steps` array with a
75ms `delay_ms` between text and submit. `inject_exit` predates that
pattern and never adopted it.

Result: `/exit` appears in the terminal but the carriage return arrives
before the TUI processes the text, so it's never submitted.

## Fix

Override `inject_exit` in Claude and Codex adapters to use the same
delayed two-step injection that `build_send_payload` uses. Keep the base
class version as a fast-path for generic/simple adapters.

### Structural changes

**`lib/harnex/adapters/base.rb`** — change `inject_exit` to accept an
optional `delay_ms` keyword (default 0) and use a two-step write:
```ruby
def inject_exit(writer, delay_ms: 0)
  writer.write("/exit")
  writer.flush
  sleep(delay_ms / 1000.0) if delay_ms.positive?
  writer.write(submit_bytes)
  writer.flush
end
```

**`lib/harnex/adapters/codex.rb`** — override:
```ruby
def inject_exit(writer)
  super(writer, delay_ms: SUBMIT_DELAY_MS)
end
```

**`lib/harnex/adapters/claude.rb`** — override:
```ruby
def inject_exit(writer)
  super(writer, delay_ms: SUBMIT_DELAY_MS)
end
```

**`lib/harnex/runtime/session.rb`** — no change needed (already calls
`adapter.inject_exit(@writer)`).

### Tests

- Add unit test: `inject_exit` with `delay_ms: 0` writes text + submit
  with no sleep
- Add unit test: `inject_exit` with `delay_ms: 75` writes text, sleeps,
  then writes submit
- Add adapter tests for Codex and Claude verifying they pass their
  `SUBMIT_DELAY_MS`

## Acceptance criteria

- [ ] `harnex stop --id <session>` causes Codex to actually exit
- [ ] `harnex stop --id <session>` causes Claude to actually exit
- [ ] Generic adapter still works (no delay)
- [ ] Tests pass

## Deferral list

- Making the exit command itself configurable (not `/exit` for all)
- Adapter-specific exit commands (Codex uses `/exit`, Claude uses `/exit`)
- Retry logic if exit doesn't take effect
