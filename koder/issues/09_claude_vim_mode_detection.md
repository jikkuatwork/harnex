---
id: 9
title: "Claude adapter doesn't detect vim normal mode as sendable state"
status: resolved
priority: P2
created: 2026-03-15
---

# Issue 9: Claude Adapter Doesn't Detect Vim Normal Mode as Sendable State

## Problem

When a Claude Code session enters vim/normal mode (user presses Escape), the
terminal prompt changes from the `>` insert-mode marker to a `NORMAL` indicator.
The Claude adapter's `input_state` detection likely doesn't recognize this as a
valid prompt state, causing the session to appear as `busy` or `unknown` to
peer agents trying to send messages.

This means relay messages sent to a Claude session in vim mode will queue
indefinitely (or timeout) instead of being delivered.

## Expected Behavior

The Claude adapter should recognize vim normal mode as a sendable state. A
message sent to a Claude session in vim mode should:

1. Detect that the session is at an input-accepting state (even if vim mode)
2. Deliver the message (which would switch back to insert mode and inject text)

Or at minimum, the adapter should report the state accurately so callers can
make informed decisions.

## Impact

In the chain-implement v2 workflow, the supervisor Claude session may be in vim
mode when a peer agent (Codex or Claude reviewer) tries to relay results back.
The relay message queues and the supervisor doesn't see it until the user
manually switches back to insert mode.

## Context

Observed during Holm chain-implement v2 session. The supervisor (Claude) had
vim mode active when peer sends were attempted. Correlation between vim mode
activation and send failures needs confirmation — filing proactively based on
the architecture.
