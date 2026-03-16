---
id: 13
title: "Atomic `send --wait` — send message and block until agent is idle"
status: open
priority: P1
created: 2026-03-16
---

# Issue 13: Atomic `send --wait`

## Problem

There is a race condition between `harnex send` and `harnex wait --until prompt`.
Immediately after `send` returns, the agent may not have transitioned from
`prompt` → `busy` yet. A subsequent `wait --until prompt` sees the stale
`prompt` state and returns instantly, before the agent has even started working.

The current workaround is `sleep 5` between send and wait:

```bash
harnex send --id cx-1 --message "implement the plan"
sleep 5
harnex wait --id cx-1 --until prompt --timeout 600
```

This works but is fragile (5s is arbitrary) and adds unnecessary latency to
every step in automated workflows.

## Discovered In

Holm's chain-implement v2 workflow, where Claude acts as supervisor orchestrating
Codex (implement) and Claude (review) workers serially. Each plan requires
2-4 send→wait cycles. The sleep adds 10-20s of dead time per plan, and across
a batch of 9 plans that's ~2-3 minutes of pure waste.

## Proposed Solution

Add a `--wait` flag to `harnex send`:

```bash
harnex send --id cx-1 --message "implement the plan" --wait --timeout 600
```

Semantics:
1. Send the message
2. Block until the agent transitions `prompt → busy → prompt`
3. Return the same JSON shape as `harnex wait --until prompt`

This makes the send+wait atomic — no race window, no sleep needed.

### Success response

```json
{"ok":true,"id":"cx-1","state":"prompt","waited_seconds":45.2}
```

### Timeout response (exit code 124)

```json
{"ok":false,"id":"cx-1","state":"busy","error":"timeout","waited_seconds":600}
```

## Implementation Notes

The key is that `send` must observe the `prompt → busy` transition before it
starts polling for the return to `prompt`. Two approaches:

1. **State fence**: After injecting the message, poll until `agent_state != prompt`
   (confirming the agent picked it up), then poll until `agent_state == prompt`
   again. Simple, no new infrastructure.

2. **Monotonic counter**: Bump a generation counter on each send. `wait` only
   considers the agent idle when the counter matches. More robust but requires
   registry changes.

Option 1 is probably sufficient — the transition to `busy` typically happens
within 1-2s of message injection.

## Impact

Eliminates the `sleep 5` workaround in every automated workflow that uses
send→wait loops. Makes harnex a reliable IPC primitive for multi-step agent
orchestration.
