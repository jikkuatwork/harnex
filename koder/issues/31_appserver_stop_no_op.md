---
status: open
priority: P2
created: 2026-05-06
tags: appserver,jsonrpc,stop,subprocess,hygiene
---

# Issue 31: `inject_exit` is a no-op for the JSON-RPC adapter; `harnex stop` only sends `turn/interrupt`

## Summary

When `harnex run codex` runs under the JSON-RPC adapter (the default
since 0.6.0), `harnex stop --id <id>` only delivers `turn/interrupt`.
The codex subprocess lives on at `state=prompt` after the interrupt,
and `harnex status` keeps reporting it as alive. Full subprocess
termination currently requires `kill -TERM <pid>` against the process
ID returned in `harnex status`.

## Reproduction

```bash
harnex run codex --tmux X --id X --context "echo done > /tmp/X.txt"
harnex wait --id X --until task_complete --timeout 60   # session done
harnex stop --id X                                      # {"ok":true,"signal":"interrupt_sent"}
harnex status                                           # X still listed, state=prompt
```

The subprocess will sit there indefinitely consuming a port + Codex
session slot until the user kills it manually.

## Root cause

`Adapters::CodexAppServer#inject_exit` is `nil`-returning by design —
PTY-style `/exit` text injection doesn't apply on the stdio JSON-RPC
transport. But there's no replacement: nothing in the stop path closes
the JSON-RPC client, releases the port, or terminates the spawned
codex subprocess. `harnex stop` therefore amounts to "interrupt the
current turn and return `ok`," which doesn't match the user's
intent ("end this session, free its slot").

## What "fixed" looks like

Three reasonable directions, pick whichever Codex's protocol supports:

1. **Native session-close RPC.** Check whether `codex app-server`
   exposes a `session/close`, `app/exit`, or similar method (probably
   in the v2 schema under `Cancel*` or `Exit*` request kinds — needs a
   read of `~/.codex/.../v2/*Params.json`). If yes: route `harnex stop`
   through that for the JSON-RPC adapter.
2. **Process-level termination after interrupt.** Send
   `turn/interrupt`, wait briefly, then `Process.kill("TERM", pid)`
   (with a `KILL` fallback after another short delay). This is what
   the spike validated as the working pattern.
3. **Hybrid.** Try (1) if available, fall back to (2). Most robust.

`Session#close` (called from the stop path) is the right surface to
extend; `inject_exit` can remain a no-op or be deleted entirely for
the JSON-RPC adapter once the close path is real.

## Acceptance test

```bash
harnex run codex --tmux X --id X --context "..."
harnex wait --id X --until task_complete --timeout 60
harnex stop --id X
sleep 1
harnex status   # session X must NOT be listed
ps -p <X-pid>   # must show "no such process"
```

## Out of scope

- The same path under the legacy PTY adapter — `inject_exit` works
  there via `/exit` injection; this issue is JSON-RPC only.

## References

- Surfaced during 0.6.3 spike validation. After `harnex stop --id cx-spike-1`
  the session reported `signal:"interrupt_sent"` but stayed in
  `harnex status` at `state=prompt` until I sent `kill -TERM 2269150`.
- See `koder/STATE.md` "2026-05-06: v0.6.3 shipped" entry, **Follow-up
  issues** subsection.
