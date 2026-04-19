---
id: 19
title: "Dispatch skill should document follow-up send pattern"
status: open
priority: P2
created: 2026-04-19
---

# Issue 19: Dispatch Skill Should Document Follow-Up Send Pattern

## Problem

The Fire & Watch dispatch skill doesn't cover how to send follow-up messages
to a running agent mid-task. In practice, the supervisor often needs to add
requirements after the initial dispatch (e.g. "also add DB size to the table").

Current behavior:
- `harnex send --id <id> --message "..."` waits for the agent to be at a prompt
- If the agent just finished but is still rendering its summary, the send times
  out (120s default) even though the agent appears idle in `harnex pane`
- `--force` bypasses prompt detection and delivers immediately, which works but
  the message may land mid-output

## Observed Scenario (2026-04-19)

1. Codex finished implementation and committed
2. Codex was writing its completion summary (still "working" from harnex's POV)
3. `harnex send` timed out twice waiting for prompt
4. `harnex send --force` delivered successfully — Codex picked it up cleanly

## Desired Improvements

### 1. Dispatch skill update

Add a "Follow-Up Sends" section to the Fire & Watch skill covering:
- Default send waits for prompt — will timeout if agent is between tasks
- Use `--force` when you can see (via `harnex pane`) the agent finished its
  work but hasn't returned to a clean prompt yet
- Use `--no-wait` for fire-and-forget when you don't need delivery confirmation

### 2. Consider smarter prompt detection (stretch)

Codex's "summary after work" phase looks like active work to harnex because the
terminal is still updating. A heuristic like "no new output for N seconds after
a git commit" could signal prompt-readiness more accurately.

### 3. Longer default timeout for send (optional)

The 120s default is fine for initial sends but tight for follow-ups when the
agent may be in a long summary/output phase. Consider a `--timeout` flag
(already exists) but document recommended values for follow-up scenarios.

## Impact

Low — workaround (`--force`) is simple and reliable. But the dispatch skill
is the primary reference for agent interaction, and this gap caused confusion
during a live supervisor session.
