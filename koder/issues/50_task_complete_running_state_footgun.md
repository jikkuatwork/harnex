---
status: open
priority: P1
created: 2026-06-09
tags: monitoring,dispatch,orchestration,completion,docs
---

# Issue 50 — `task_complete=true` with `state=running` is a completion footgun for queue monitors

## Problem

Structured app-server workers can finish the assigned task, emit
`task_complete`, write the expected artifact, and return to an interactive
prompt while the harnex process remains live. In that state
`harnex status --json --id <id>` reports:

```json
{
  "agent_state": "prompt",
  "state": "running",
  "terminal": false,
  "task_complete": true,
  "last_completed_at": "..."
}
```

That is internally consistent: the session process is still running. But it is a
high-risk orchestration footgun because queue monitors often read `state` as the
completion predicate. A monitor that waits for `state=completed` can stall
indefinitely even though the work-level completion event already fired.

## Source incident

Holm Queue `020-01`, dispatch `cx-p-523`, 2026-06-09:

- Codex completed Plan `523.S00` mapping at `00:21:59 IST`.
- The expected artifact existed:
  `koder/plans/523_S00_issue399_provider_chain_accounting_remap/INDEX.md`.
- `harnex status --json --id cx-p-523` showed `task_complete=true`,
  `agent_state=prompt`, and `last_completed_at` populated, but still
  `state=running` / `terminal=false` because the interactive session was alive.
- The Holm watcher loop checked only `state=completed`, so it kept sleeping and
  would have stalled until manual intervention.
- Recovery was immediate after switching the next step to:
  `harnex wait --id cx-r-523 --until task_complete --timeout 5400`.

Holm docs were patched locally to state: `task_complete` is the primary
completion signal; `state` and pane output are diagnostic. Harnex should encode
that lesson upstream so every downstream project does not rediscover it.

## Related

- #25 — first-class task-complete signal (superseded by app-server transport).
- #48 — terminal summaries are canonical over tmp done markers.
- #49 — bare `harnex wait` waits for process exit and hangs on interactive agents.

This issue is distinct from #49: even callers who avoid bare `wait` can still
write a broken monitor if status examples or helper scripts emphasize
`state=completed` instead of the work-level `task_complete` predicate.

## Desired behavior

Make the work-completion path impossible to miss:

1. Documentation and guide examples should show `harnex wait --until
   task_complete` as the primary monitor for Codex/Pi app-server dispatches.
2. `harnex status --json` should expose an obvious work-level predicate, such as
   `work_state: "completed"` or `done: true`, when `task_complete=true` even if
   the process-level `state` remains `running`.
3. If harnex keeps `state=running` for live interactive sessions, docs must label
   it clearly as **process/session state**, not work completion state.
4. Add a `--until done` alias or equivalent helper that resolves on
   `task_complete` or terminal exit, whichever comes first.
5. Any harnex recipes, agents-guide examples, or sample sweep loops should never
   gate completion on `state=completed` alone.

## Proposed acceptance criteria

- [ ] `harnex agents-guide monitoring` and README monitoring examples put
      `harnex wait --id <id> --until task_complete` before state/pane polling.
- [ ] JSON status includes a clear task/work completion field that downstream
      scripts can check without interpreting process state.
- [ ] Tests cover an active interactive session with `task_complete=true` and
      `state=running`; the documented work-level predicate reports done.
- [ ] `harnex wait --until done` or a similarly named alias resolves when the
      task completes even if the session remains alive at a prompt.
- [ ] Examples explicitly state that pane output and process `state` are
      diagnostics after the work-level signal, not the primary done signal.

## Non-goals

- Do not make all interactive sessions auto-stop by default.
- Do not remove process/session `state=running`; that state is useful when
  correctly labeled.
- Do not require downstream projects to create tmp done markers for structured
  app-server dispatches.
