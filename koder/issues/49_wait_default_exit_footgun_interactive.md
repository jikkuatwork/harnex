---
status: open
priority: P2
---

# Issue 49 — `harnex wait` (default exit mode) silently hangs on interactive agents that already completed

**Status**: open
**Priority**: P2
**Filed**: 2026-06-01
**Source incident**: Holm, dispatch `cx-p-500` (Plan 500 / Issue 397)
**Related**: #38 (reject unknown run flags), #48 (terminal summary canonical over done markers)

## Problem

`harnex wait --id <id>` with **no `--until`** waits for *session process exit*.
For an interactive agent (codex, claude) the process does **not** exit when a
turn finishes — it returns to its prompt and stays alive. So a bare `harnex
wait` blocks until its `--timeout`, even though the session emitted
`task_complete` seconds in.

This is a silent footgun for orchestrators: the dispatch *succeeded*, the
`task_complete` event fired and is queryable, but the watcher reports nothing
until the timeout. The orchestrator concludes "completion detection failed"
when in fact it waited on the wrong predicate.

Adjacent to #48 (queue monitor trusted a missing `/tmp` done-marker over the
terminal summary) but distinct: this is the `wait` command's own default
predicate, not a queue monitor or a done-marker.

## Repro

```text
harnex run codex --id cx-1 --tmux cx-1 -- ...        # no --auto-stop
# ... agent finishes the turn, emits task_complete, sits at prompt ...
harnex wait --id cx-1 --timeout 1800
  -> blocks ~1800s, then resolves only because of timeout (or an external stop)

harnex wait --id cx-1 --until task_complete --timeout 1800
  -> returns in ~0.0s: {"ok":true,"event":"task_complete","waited_seconds":0.0}
```

Confirmed on harnex 0.7.5 (2026-05-26): the already-completed session's
`--until task_complete` wait resolved in 0.0s, while a concurrently-running
default `harnex wait` never resolved until the session was stopped.

## Proposed fix (any one, cheapest first)

1. **Hint on entry.** When `harnex wait` is invoked with no `--until` against a
   session whose adapter is interactive (does not self-exit) — or one that has
   *already* emitted `task_complete` — emit a one-line stderr hint:
   `note: session has reached task_complete and will not exit on its own; did
   you mean --until task_complete? (waiting for process exit)`. Cheap, no
   behavior change.
2. **Short-circuit option.** Accept `--until done` (alias) that resolves on
   `task_complete` *or* exit, whichever comes first, so a bare-ish wait "does
   the obvious thing."
3. **Doc/UX.** Make `--until task_complete` the prominent default example in
   `harnex run`'s post-dispatch hint output (the line printed after a
   successful `run`), so the correct watcher is copy-pasteable at dispatch time.

Option 1 alone would have prevented this incident.

## Why it matters

The single most common orchestrator operation is "watch this dispatch to
completion." The default `harnex wait` does the non-obvious thing for the most
common agent type (interactive), and fails *silently* (timeout, not error). A
one-line guard converts a 30-minute silent hang into an immediate course
correction.
