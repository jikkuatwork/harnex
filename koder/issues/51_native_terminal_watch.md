---
status: open
priority: P1
created: 2026-06-13
updated: 2026-06-13
tags: monitoring,dispatch,orchestration,watch,wait,task_failed
---

# Issue 51 — Make native watch work-terminal aware (`task_complete` / `task_failed`)

## Problem

`harnex wait --until done` now exposes the correct work-level signal and returns
non-zero on `task_failed`, and harnex already has built-in watch mode
(`harnex run --watch` / `Harnex::RunWatcher`). But the current watcher is
primarily an activity/stall babysitter: it polls `/status`, nudges idle sessions,
and exits on process/session exit or resume exhaustion. It does not make
work-terminal `task_complete` / `task_failed` the primary contract for existing
visible `--tmux` / detached dispatches.

Downstream repos therefore still hand-roll watcher loops around `harnex wait
--until done`. Those wrappers can accidentally treat any non-zero wait result as
"keep polling" and continue after a terminal failure.

That happened in Holm Queue `030` on 2026-06-13:

- `cx-i-030` completed two queue entries, then Codex app-server failed during a
  later entry with a model-side stream error.
- harnex correctly emitted `task_failed`, `work_state=failed`, and a non-zero
  `harnex wait --until done` result.
- The repo-local bash watcher then ran `scripts/harnex/sweep.sh ... || true`,
  swallowed the failure, and kept polling a dead worker.
- A continuation attempt (`cx-i-030b`) hit the same failure shape and exposed the
  same wrapper footgun.

This is not a missing harnex signal; it is an ergonomics gap. Harnex provides
the primitive and a stall watcher, but not the safe, copy-pasteable
work-terminal watcher that most unattended `--tmux` / detached dispatch users
need.

## Related

- #49 — bare `harnex wait` waits for process exit and is a footgun for
  interactive agents.
- #50 — `task_complete=true` with `state=running` is a monitor footgun; released
  `--until done`, `done`, and `work_state`.
- #42 — durable app-server orchestrator recovery; this issue is narrower and is
  about watcher CLI ergonomics, not automatic Codex recovery.

## Desired behavior

Extend the existing native watch surface, or add a closely related mode, so it
can watch an existing dispatch by work-level terminal state. Example shape:

```bash
harnex watch --id cx-i-030 \
  --until done \
  --max-wait 5400 \
  --done-marker /tmp/cx-i-030-done.txt \
  --fail-marker /tmp/cx-i-030-failed.txt \
  --stop-on-terminal
```

The exact CLI shape can differ. It could also be `harnex run --watch --until
done` for foreground launches plus `harnex watch --id` for existing sessions.
The important property is that the safe path is obvious:

- Exit `0` when the work completes successfully (`task_complete` / `done`).
- Exit non-zero when the work fails (`task_failed`, terminal failed summary, or
  failed process exit without successful work completion).
- Distinguish timeout/wall-clock-cap from task failure with a separate exit code
  or explicit JSON status.
- Optionally write done/fail marker files for legacy queue integrations.
- Optionally stop the session on terminal success/failure.
- Avoid pane/status polling after a terminal `task_failed` signal.

## Reference workaround

Holm added a repo-local tactical wrapper after the incident:

```text
scripts/harnex/watch.sh
```

That script is not the desired final home for the behavior. It is a reference
implementation for harnex proper: wait on the work-level `done` fence, treat
`task_failed` as terminal, run sweep/resume logic only after wait timeouts, and
enforce a wall-clock cap.

## Acceptance criteria

- [ ] `harnex watch --id <id> --until done` or an equivalent built-in surface
      exists for existing visible/detached sessions.
- [ ] Tests cover a successful `task_complete` / `done` result and exit `0`.
- [ ] Tests cover a `task_failed` event from `wait --until done`; the watcher
      exits non-zero immediately and does not continue pane/status polling.
- [ ] Tests cover a terminal failed summary when no live registry/session exists.
- [ ] Tests cover wall-clock timeout/cap behavior as distinct from task failure.
- [ ] Docs and `agents-guide monitoring` examples use the native work-terminal
      watcher for unattended single-dispatch monitoring, and distinguish it from
      activity/stall-only babysitting.
- [ ] Existing `harnex wait --until done` behavior remains intact for callers who
      need the primitive directly.

## Non-goals

- Do not auto-recover failed Codex app-server turns in this issue; that belongs
  to #42.
- Do not change the meaning of `state=running` for live interactive sessions.
- Do not require all sessions to auto-stop on task completion.
- Do not remove `harnex wait`; this issue adds a safer higher-level wrapper for
  the common unattended-monitoring case.
