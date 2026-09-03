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

For unattended sessions, combine bounded watcher calls with the runner-owned
push path. Every session writes
`$HARNEX_STATE_DIR/done/<repo-key>--<id>.<outcome>` at its first work-terminal
result. `harnex run --on-done CMD` can also launch one non-blocking local hook,
even without a watcher and while the agent remains alive at a prompt:

```bash
harnex run pi --id pi-i-NN --tmux pi-i-NN --context "Read the task brief" \
  --auto-stop \
  --on-done 'printf "%s %s\n" "$HARNEX_ID" "$HARNEX_OUTCOME" >> koder/scratch/HARNEX_WAKE.txt'
harnex watch --id pi-i-NN --until done --max-wait 30m
```

Use a gitignored wake destination. `CMD` is trusted shell input; never embed
secrets. It receives `HARNEX_ID`, `HARNEX_OUTCOME`, `HARNEX_WORK_STATE`,
`HARNEX_RECEIPT_PATH`, `HARNEX_END_SHA`, and `HARNEX_ELAPSED_S`. `completed`
wakes the consumer but does not certify the prose; verify the receipt and
artifact before acting.

`harnex watch --until done` returns on the work-level `task_complete` or
`task_failed` signal, or terminal exit, whichever comes first. Successful work
exits `0`, failed work exits non-zero, and wall-clock caps exit `124`. For
callers that need the lower-level primitive, `harnex wait --until done` exposes
the same work fence. Do not park an orchestrator in one unbounded watcher call.

## Live-Run Visibility

Every dispatch appends a `dispatch_start` row to the repo's dispatch stream
(`.harnex/dispatch.jsonl`) at registration; the `dispatch_end` row at teardown
completes it. Between those two rows the run is visible to every documented
signal, from any cwd in the same repo:

- `harnex status --id X` reports settled work as `done`, `rejected`, or
  `failed` even while the adapter is back at `prompt`. When work is unsettled,
  it reports the adapter input state. If the live HTTP status API is
  unreachable it still reports running from the
  registry (or, failing that, from the uncompleted start row) and labels the
  row `degraded: true` with `source` set to `registry` or `dispatch_start`.
- `harnex history` shows uncompleted dispatches as `running` (pid alive) or
  `interrupted` (pid gone, no end row). Completed dispatches render one
  `dispatch_end` row.
- `harnex wait --until done` blocks while the session's pid is alive, up to
  `--timeout`. "No signal yet" from a live worker is never terminal.

A monitor consulting these signals can never classify a healthy mid-run
worker as dead. If `status` says running, do not dispatch a replacement.

## `wait --until done` Exit-Code Contract

| Code | `wait_result` | Meaning |
| --- | --- | --- |
| `0` | `done` | Completed with accepted work |
| `1` | `failed` | Work failed, process failed, or killed |
| `2` | `rejected_proof` | Completed but proof rejected (`completed_no_activity`, `report_missing`, `report_invalid`, `report_rejected`) |
| `3` | `no_such_session` | No live, start, event, or terminal signal for the id |
| `124` | `timeout` | `--timeout` elapsed while the session was still running |

The JSON payload always carries `wait_result` plus the work-state fields
(`done`, `work_state`, `outcome_class`, `artifact_report_status`). The child
process's own exit code is reported as data (`exit_code`), never passed
through as wait's exit status. Treat `2` as a work-acceptance failure, `3` as
a coordination error (wrong id or wrong repo), and only `0` as success.

## Duplicate-Dispatch Guard

`harnex run --attempt-kind retry|fallback` requires
`--parent-dispatch-id`, and any retry/fix/fallback/superseding dispatch whose
named parent is still running in the same repo is refused. Wait for the parent
(`harnex wait --id <parent> --until done`) or stop it first. Pass
`--allow-live-parent` only for intentional parallelism (e.g. isolated
worktrees). `--attempt-kind review` is exempt: a completed parent may still
sit at a live prompt while its work is reviewed. For structured sessions (Pi
RPC and Codex app-server), `harnex wait --until task_complete` remains the exact
accepted-turn fence. Pi reaches that fence only at `agent_settled`; an earlier
`agent_end` can still be followed by retry, compaction recovery, or queued work.
Final Pi `error`, `aborted`, and `length` stop reasons emit `task_failed`.
Codex acknowledgment-only auto-stop turns are typed
`completed_no_activity` and fail this fence without transcript parsing. Harnex
writes the observed-state receipt before publishing `task_complete`; optional
worker claims never make an inactive turn pass. Harnex still does not judge
semantic quality, so verify the expected artifact or tests afterward.

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
(the v2 `dispatch_end` in `.harnex/dispatch.jsonl`, an explicit mirror when
configured, or exit status), returns non-zero for `task_failed` / failed
terminal telemetry, returns `124` for `--max-wait`, and
only writes done/fail markers as compatibility outputs after harnex has seen a
terminal work signal.

Adjust the artifact path to the task. The point is to avoid declaring done while
a worker is between edits or between commits.

In repos that track the dispatch stream (`.harnex/dispatch.jsonl`), exclude it
from the clean-tree check — harnex appends to it during every run, so it is
legitimately dirty mid-run:

```bash
test -z "$(git status --short -- . ':!.harnex')"
```

Never treat harness-owned telemetry as foreign dirt, and never instruct a
worker to revert or "clean up" the stream to satisfy a fence.

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
- Blocking orchestrators on caller-owned `/tmp/*-done.txt` as the only completion signal.
- Using one long watcher call without the runner-owned marker or `--on-done` push path.
- Letting an unattended loop run with no wall-clock cap.
- Reading raw tmux panes instead of `harnex pane`.
- Using `--wait-for-idle` as acceptance proof.
- Reusing a worker after a failure changes the task scope.
- Claiming "no live sessions" from memory. Finished agents park at prompts
  indefinitely; sweep proven-done sessions, then prove the claim with
  `harnex status`.
- Failing a clean-tree fence on `.harnex/dispatch.jsonl` growth in repos that
  track the dispatch stream.
