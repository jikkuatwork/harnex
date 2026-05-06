---
id: 8
title: "Send to fresh Codex session times out before first prompt"
status: resolved
priority: P2
created: 2026-03-15
---

# Issue 8: Send to Fresh Codex Session Times Out Before First Prompt

## Problem

When spawning a Codex session and immediately sending a message, the send can
timeout (default 30s) because Codex hasn't reached its first prompt yet. The
message gets queued (HTTP 202) but the delivery poll exhausts the timeout budget
waiting for the session to transition from `unknown` to `prompt`.

## Reproduction

```bash
harnex run codex --id cx-test --tmux cx-test -- --cd /path/to/large-repo
sleep 5
harnex send --id cx-test --message "do something"
# → timeout after 30s, message stuck in pending queue
```

Codex startup in a large repo (reading CLAUDE.md, indexing files) can take
30-60+ seconds before it shows a prompt. The harnex send default timeout of 30s
is insufficient.

## Observed During

Chain-implement v2 workflow in Holm repo. Spawning `cx-159` and sending the
implementation prompt — send timed out, message stayed queued (pending: 1,
delivered: 0). Message eventually delivered when Codex reached prompt, but the
supervisor had already received a timeout error.

## Expected Behavior

The message should reliably deliver even if the agent takes a long time to start.
The sender should either:

1. Have a longer default timeout for fresh sessions, or
2. Return the queued message_id immediately (like `--no-wait`) and let the
   caller poll/wait separately, or
3. Detect "session exists but hasn't reached first prompt" and use a longer
   wait budget

## Workaround

Use `--no-wait` and handle delivery tracking separately, or add a manual
`sleep` before the first send to a fresh session.
