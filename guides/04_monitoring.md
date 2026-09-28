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

For unattended sessions, combine owner-addressed delivery with bounded native
watching. Every session writes
`$HARNEX_STATE_DIR/done/<repo-key>--<id>.<outcome>` at its first work-terminal
result. A Pi-launched dispatch also registers a durable per-owner, per-attempt
record under `$HARNEX_STATE_DIR/notifications/` before its initial structured
prompt, then atomically settles it at terminal work. The runner captures the
invoking Pi shell's `PI_SESSION_ID`; nested workers are excluded unless an
external owner is explicitly named with `--orchestration-session-id`.

```bash
harnex run pi --id pi-i-NN --tmux pi-i-NN \
  --context "Read the task brief" --auto-stop
harnex watch --id pi-i-NN --until done --max-wait 15m --heartbeat 60s
```

The consumer must match owner and attempt identity, verify the exact Harnex
receipt, and persist acknowledgment before continuing. It must not erase a
shared signal before delivery. `harnex run --on-done CMD` remains an optional
non-blocking integration hook; `CMD` is trusted shell input, receives the typed
`HARNEX_*` completion values, and must not target a destructive shared queue.
`completed` is still only a wake: verify the artifact and acceptance gates.

`harnex watch --until done` returns on the work-level `task_complete` or
`task_failed` signal, or terminal exit, whichever comes first. Successful work
exits `0`, failed work exits non-zero, and observer caps exit `124`. For
callers that need the lower-level primitive, `harnex wait --until done` exposes
the same work fence. Do not park an orchestrator in one unbounded watcher call.

## Heartbeats and Hard Observer Caps

For LLM callers, opt in to `--heartbeat 60s` on `wait` or `watch`. While the
observer is blocked, it flushes a diagnostic line to **stderr** at each interval:

```text
harnex wait: id=pi-i-NN waited=60.0s state=running last_event=started seq=1
```

These are the last observed state/event/sequence, not evidence of model or tool
progress. Unknown observations remain `unknown`; a slow probe does not prevent
heartbeats, but the snapshot can be stale. Neither UI repaint nor log freshness
is interpreted as work activity. Heartbeats are off by default, including for
JSON consumers. Even when enabled, stdout remains **one final JSON result**;
consume stderr live rather than combining/buffering the streams until exit.

`wait --timeout DUR` (alias `--max-wait`) and `watch --max-wait DUR` (alias
`--timeout`) accept finite positive durations in seconds or with `s`, `m`, `h`
suffixes. The cap uses a monotonic clock and includes repo resolution, registry
and event reads, status HTTP, and final-event/exit-status grace. Heartbeats and
new events never reset it. A late probe result cannot turn an expired observer
into success. Timeout exits `124`, without stopping the live worker or writing
compatibility done/fail markers, even with `--stop-on-terminal`.

This bounds the **observer**, not worker runtime. The timed/heartbeat observer
uses a short-lived, isolated read-side child; cancellation kills and reaps that
child, not the session. Slow Ruby probes, HTTP, and even slow Ruby cleanup are
bounded by the cap plus at most one poll and scheduling tolerance. This is not a
promise to preempt uninterruptible kernel I/O or OS scheduling stalls. Output
consumers must keep draining streams. Optional marker writes and
`--stop-on-terminal` are post-observation actions, not read-side probes.

## Worker Runtime Budgets, Activity, and Stops

A watcher timeout stops **waiting**, not working. To cap the worker itself,
first require `harnex doctor --adapter pi` to report `ok: true` and
`capabilities.runtime_budget: 1` (available in Harnex 0.14.0+), then opt in:

```bash
harnex run pi --id cx-i-NN --tmux cx-i-NN \
  --context "Read the task brief" --auto-stop --max-runtime 30m
harnex watch --id cx-i-NN --max-wait 5m --heartbeat 60s
```

`--max-runtime` is a fixed monotonic budget in the session-owning runner. It is
armed before child launch/initial prompt, after binary validation, and never
reset by prompts, retries, UI chatter, or activity. Expiry requires no supervisor:
it terminates the owned worker process group with bounded TERM/KILL escalation
without waiting for an abort RPC, startup handshake, receipt lock, or runner
stdout. Normal descendant processes in that group are included; descendants
which deliberately create a different group/session are not contained. This is
not an OS sandbox. Child shutdown and receipt/telemetry finalization can take
additional time and still require working I/O/drained output; this is not a
promise to preempt OS scheduling or uninterruptible I/O.
Active work is failed with logical run exit `124`. Expiry used only to clean up
already accepted idle work preserves that proof and logical exit `0`. The stop
record says `runtime_budget` when expiry was the first requested stop. An earlier
stop keeps its original labels but cannot disable the cap: `runtime_budget.enforced`
and its timestamp plus `runtime_budget_expired` record actual enforcement
independently. Without this option there is no runtime cap.

`status --json` and dispatch-end records expose separate `activity` and
`runtime_budget` objects:

- `activity.turn_active`, `turn_started_at`, `turn_age_s` track the current
  structured run, including quiet waits and retries.
- `model_active`, `model_started_at`, `model_age_s` describe the observed
  assistant stream/item lifetime, not hidden provider internals.
- `last_model_activity_at` / `model_idle_s` and `last_tool_activity_at` /
  `tool_idle_s` track their respective protocol events. Thinking deltas advance
  the model clock without retaining their content in the activity tracker.
- UI requests, queue updates, log mtime, and status reads never advance work
  clocks. A new run clears the prior run's activity clocks; steering an active
  run does not. PTY/unobserved activity is `status: unknown` with null clocks.
- Existing `log_idle_s` and the status table's `IDLE` column remain **log age**,
  not work progress. A degraded registry snapshot is stale, not a fresh sample.

Stops record bounded caller-declared labels, separately from work acceptance:

```bash
harnex stop --id cx-i-NN --reason manual --origin cli
```

Reasons are `manual`, `completion`, `runtime_budget`; origins are `api`, `cli`,
`auto_stop`, `watch`, `runtime`. These labels are not authenticated identities.
The first stop request wins. Inspect the `stop_requested` event, live/terminal
`stop` metadata, or receipt `observed.stop` for reason, origin, request time,
work state at request, and an applicable runtime limit. Harnex's own budget
expiry requests `runtime_budget`/`runtime` unless a prior stop already won;
auto-stop uses `completion`/`auto_stop`;
`watch --stop-on-terminal` uses `completion`/`watch`. Raw child status remains in
`process_exited` for Pi and budgeted runs when observed (startup failure may
have no raw wait status); the final run exit is logical status.

Explicit idle Pi cleanup preserves the latest settled accepted/no-change proof,
including after follow-up turns. Busy stop rejects unfinished work and cannot
reuse an older accepted turn. Unexpected EOF, malformed/truncated JSONL, and abnormal
idle teardown remain failures. Completion notifications remain once per session,
not once per reusable turn; verify the receipt appropriate to each turn.

Pi `send --force` while busy queues steering for a subsequent assistant turn.
Transport/queue acceptance is not proof the current model call consumed it.
Consumer wake deduplication/acknowledgment still belongs in the Pi bridge.

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
| `124` | `timeout` | Observer cap elapsed before a result was obtained; worker is not stopped |

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
harnex watch --id pi-i-NN --until done --max-wait 15m --heartbeat 60s
# Primitive equivalent when a script wants raw wait semantics:
harnex wait --id pi-i-NN --until done --timeout 900 --heartbeat 60s
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
- Using one long watcher call without the runner-owned marker or owner-addressed delivery path.
- Letting an unattended loop run with no wall-clock cap.
- Reading raw tmux panes instead of `harnex pane`.
- Using `--wait-for-idle` as acceptance proof.
- Reusing a worker after a failure changes the task scope.
- Claiming "no live sessions" from memory. Finished agents park at prompts
  indefinitely; sweep proven-done sessions, then prove the claim with
  `harnex status`.
- Failing a clean-tree fence on `.harnex/dispatch.jsonl` growth in repos that
  track the dispatch stream.
