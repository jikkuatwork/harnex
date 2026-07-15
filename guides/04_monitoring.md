# Monitoring Patterns

Monitoring should be based on work-level signals first and UI state second.
Pane state is useful for interpretation, but it should not be the only proof
that delegated work is finished.

## Signal Ladder

Prefer signals in this order:

| Signal | Use |
| --- | --- |
| Expected artifact | Primary proof that a task produced its deliverable |
| Tests and git state | Confirms work landed and the tree is not mid-edit |
| `harnex events` | Structured runtime events, including task completion |
| `harnex logs` | Transcript history and last output |
| `harnex pane` | Live UI interpretation and prompt/error diagnosis |
| `harnex status` | Session liveness and coarse state |

For unattended monitors on existing visible/detached sessions, prefer
`harnex watch --until done`: it returns on the work-level `task_complete` or
`task_failed` signal, or terminal exit, whichever comes first. Successful work
exits `0`, failed work exits non-zero, and wall-clock caps exit `124`. For
callers that need the lower-level primitive, `harnex wait --until done` exposes
the same work fence. For structured sessions (Pi RPC and Codex app-server),
`harnex wait --until task_complete` remains the exact accepted-turn fence.
Codex acknowledgment-only auto-stop turns are typed
`completed_no_activity` and fail this fence without transcript parsing.
`--require-artifact-report` can additionally make sidecar shape/final-proof
acceptance part of the verdict. Harnex still does not judge semantic quality;
verify the expected artifact or tests afterward.

## Completion Test

For unattended work, first gate on harnex work completion, then verify the task
artifact and repo health:

```bash
harnex watch --id pi-i-NN --until done --max-wait 90m \
  --done-marker /tmp/pi-i-NN-done.json \
  --fail-marker /tmp/pi-i-NN-failed.json &&
  test -f path/to/expected-artifact &&
  test -z "$(git status --short)"
```

`harnex watch --until done` wraps the `harnex wait --until done` work fence:
it succeeds from `task_complete` or durable successful terminal telemetry
(`--summary-out` / `.harnex/dispatch.jsonl` / exit status), returns non-zero for
`task_failed` / failed terminal telemetry, returns `124` for `--max-wait`, and
only writes done/fail markers as compatibility outputs after harnex has seen a
terminal work signal.

Adjust the artifact path to the task. The point is to avoid declaring done while
a worker is between edits or between commits.

## Why Pane State Alone Is Not Enough

Avoid using `state=prompt` or a quiet pane as the only completion signal:

- A finished agent can sit at a prompt forever.
- Some CLIs stay in a session state while auto-fix or tool loops continue.
- Focus changes and UI redraws can reset idle timers.
- A prompt can also mean the agent is blocked, not done.

Use `harnex pane` to understand what happened after a stronger signal tells you
where to look.

## Polling Patterns

For active supervision:

```bash
harnex pane --id pi-i-NN --lines 40
harnex events --id pi-i-NN --snapshot
harnex logs --id pi-i-NN --lines 80
```

For continuous viewing:

```bash
harnex pane --id pi-i-NN --follow --interval 2
harnex logs --id pi-i-NN --follow
harnex events --id pi-i-NN
```

For task completion:

```bash
harnex watch --id pi-i-NN --until done --max-wait 15m
# Primitive equivalent when a script wants raw wait semantics:
harnex wait --id pi-i-NN --until done --timeout 900
# Or, when you specifically need the structured successful-turn event:
harnex wait --id pi-i-NN --until task_complete --timeout 900
```

## Background Sweeper

Avoid custom shell loops that repeatedly call `harnex wait`/`harnex status` and
then accidentally swallow a failed work result. For a single unattended
visible/detached dispatch, use the native watcher with a hard wall-clock cap:

```bash
harnex watch --id pi-i-NN --until done --max-wait 90m \
  --done-marker /tmp/pi-i-NN-done.json \
  --fail-marker /tmp/pi-i-NN-failed.json
```

If that exits `124`, inspect the pane/logs/events and decide whether to nudge,
stop, or continue. If it exits any other non-zero code, inspect
`outcome_class` / `artifact_report_status` in the JSON or fail marker, treat the
work as failed, and do not continue polling the same task as though it were
still running. `completed_no_activity`, `report_missing`, `report_invalid`, and
`report_rejected` are work-acceptance failures rather than successful turns.

Recommended caps:

| Work type | Cap |
| --- | --- |
| Small single dispatch | 30 minutes |
| Medium implementation | 90 minutes |
| Large unattended phase | 3 hours |

## Built-In Stall Babysitter

Use `harnex run --watch` when one foreground process should launch the worker
and apply bounded stall recovery. This is different from `harnex watch --id`,
which watches an existing session's work-terminal state:

```bash
harnex run pi --id pi-i-NN --watch --preset impl \
  --context "Read /tmp/task-impl-NN.md"
```

`run --watch` exits with:

| Code | Meaning |
| --- | --- |
| `0` | Session exited |
| `1` | Operational error |
| `2` | Watcher escalated after bounded resumes |

Use a buddy instead when the monitoring decision needs language-level
interpretation.

## Anti-Patterns

- Polling `state=completed` alone and missing live sessions with `task_complete=true`.
- Polling `state=prompt` alone and calling it done.
- Wrapping `harnex wait` in loops that swallow non-zero `task_failed` results.
- Blocking orchestrators on `/tmp/*-done.txt` as the only completion signal.
- Letting an unattended loop run with no wall-clock cap.
- Reading raw tmux panes instead of `harnex pane`.
- Using `--wait-for-idle` as acceptance proof.
- Reusing a worker after a failure changes the task scope.
