---
status: open
priority: P0
created: 2026-06-09
updated: 2026-06-09
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

## Review turn — 2026-06-09

**Verdict:** Valid Holm-blocking issue. Treat as P0 until the bundled
monitoring guidance and one safe machine predicate are shipped; the underlying
runtime state is internally correct, but the public ergonomics still steer
queue monitors toward a known indefinite-wait failure mode.

### Findings

- **P0-1 — Existing bundled examples still contain the exact footgun.**
  `lib/harnex/commands/status.rb:102-105` intentionally normalizes every live
  session to `state=running` / `terminal=false`, even after
  `last_completed_at`. That is fine as process state, but
  `guides/04_monitoring.md:94-98` still shows a background sweeper that reads
  only `state` and breaks only on `completed`; `guides/03_buddy.md:57` gives a
  buddy prompt with the same `state=completed|failed` gate. Holm copied this
  pattern class of monitor, so docs-only consumers remain exposed.
- **P0-2 — The issue should be framed as ergonomics, not missing raw data.**
  Live JSON already carries `task_complete` and `last_completed_at`, and README
  now mentions `wait --until task_complete`. The blocker is that the easiest
  status field and several examples still look like the completion contract.
  The fix should add an unmistakable work-level predicate and remove stale
  state-only loops.
- **P1-1 — Prefer explicit split fields over overloading `state`.** Keep
  `state=running` for compatibility, but add e.g. `process_state: "running"`,
  `work_state: "completed|running|failed|unknown"`, and/or `done: true|false`.
  A bare `done` boolean is useful for shell loops; `work_state` explains why it
  is true when process state remains running.
- **P1-2 — `--until done` should not be a shallow alias.** It should resolve on
  a `task_complete` event for live structured sessions, or on terminal
  exit/terminal-summary recovery when no task-complete event appears. Failed
  terminal exits should still return non-zero. Current `wait --until
  task_complete` is event-log centric and does not consult terminal summaries
  when the registry/events path is gone, so `done` likely needs a dedicated
  path rather than only adding another entry to `EVENT_PREDICATES`.

### Recommended slice for Holm unblock

1. Add a status work predicate (`done` plus `work_state`, or equivalent) for
   live, terminal, and unknown rows. For the source incident shape, JSON should
   show `state: "running"`, `task_complete: true`, `done: true`, and
   `work_state: "completed"`.
2. Add `harnex wait --until done` with tests for both: (a) live session emits
   `task_complete` and stays alive; (b) process exits/terminal summary resolves
   before task completion.
3. Patch `guides/04_monitoring.md` background sweeper and `guides/03_buddy.md`
   prompt to gate on `wait --until done` or the new status predicate, never on
   `state=completed` alone. Add `state=completed`-only polling to
   Anti-Patterns.
4. Keep README's existing `task_complete` guidance, but add one sentence that
   `state` is process/session state while `done`/`work_state` is the work-level
   monitor contract.

### Acceptance tweak

Add an explicit acceptance criterion: sample shell loops must pass when a live
interactive session reports `state=running`, `agent_state=prompt`, and
`task_complete=true`; they must not wait for `state=completed`.
