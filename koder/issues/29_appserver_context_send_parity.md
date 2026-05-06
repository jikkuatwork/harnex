---
status: open
priority: P1
created: 2026-05-06
tags: transport,appserver,bug,regression
---

# Issue 29: app-server adapter — `--context` and `harnex send` parity

## Summary

`harnex 0.6.0`'s `codex_appserver` adapter ships `#dispatch` for the
stdio_jsonrpc transport, but two harnex CLI surfaces still trip
`build_send_payload`'s `NotImplementedError`:

1. `harnex run codex --context "<text>"` — the initial `--context`
   delivery fails. The session disconnects at boot and never registers
   (event: `disconnected source=transport`).
2. `harnex send --id <id> --message "<text>"` against an app-server
   session — times out after 120s with `delivery timed out` even when
   the session reports `state=prompt`.

PTY adapter is unaffected; `--legacy-pty` works as a workaround.
Observed live during the `cx-i-h28` dispatch on 2026-05-06; that
dispatch fell back to `--legacy-pty` to deliver the brief.

## Reproducer

```bash
# (a) --context delivery
harnex run codex --tmux --id repro-a --description "repro 29a" --context "hi"
# Expected: boots, delivers "hi". Actual: source=transport disconnect.

# (b) harnex send mid-session
harnex run codex --tmux --id repro-b --description "repro 29b"
# wait for state=prompt
harnex send --id repro-b --message "hello"
# Actual: delivery timed out after 120.0s.
```

## Acceptance Test

After the fix, both succeed without `--legacy-pty`:

```bash
harnex run codex --tmux --id ax-29-a --description "accept" --context "ok"
harnex send --id ax-29-a --message "hello"
```

## Workaround Until Fixed

Pass `--legacy-pty` on any dispatch needing `--context` or `harnex send`.

## References

- `lib/harnex/adapters/codex_appserver.rb:81` — `NotImplementedError` site
- `lib/harnex/runtime/session.rb` — `inject_via_adapter`,
  `inject_via_jsonrpc`, `#dispatch`
- holm `koder/STATE.md` 2026-05-06 PM — first observation during `cx-i-h28`
