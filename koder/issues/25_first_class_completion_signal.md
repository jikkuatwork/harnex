---
status: closed
closed_in: harnex-0.6.0
priority: P1
created: 2026-05-02
superseded_by: 27_codex_appserver_adapter
tags: monitoring,dispatch,orchestration,completion
---

# Issue 25: First-class "task complete" signal for dispatched workers

## Status

**Superseded by Issue 27 (2026-05-06).** The architectural pivot to
`codex app-server` transport delivers `turn/completed` as a
first-class JSON-RPC notification — the exact "positive signal a worker
has completed its task" this issue spec'd. Both proposals (heuristic
adapter detection + worker-side `harnex done` callback) become
unnecessary when the transport itself emits structured completion
events. The 6-hour overnight idle incident this issue was filed for
becomes structurally impossible post-#27. See
`27_codex_appserver_adapter.md`.

Originally filed after a real incident (holm 2026-05-01 → 02 overnight
chain) where an orchestrator sat idle for ~6 hours waiting on a
completion event that never came.

Sister issues:
- `22_built_in_dispatch_monitoring.md` (fixed) — log-mtime + bounded resume
- `23_dispatch_telemetry.md` — telemetry surface
- `24_disconnect_detection.md` — Codex stream disconnect detection

This issue is **upstream of 22 / 24**: we lack the positive signal a worker
has actually finished its task, independent of pane state, log activity, or
session exit.

## The Problem

Every orchestrator that dispatches Codex reinvents a "task done" inference,
and each variant has subtle bugs.

The signals harnex currently exposes are all **pane-level**, not
**work-level**:

| Signal | What it measures | Failure mode for "task done" |
|--------|------------------|------------------------------|
| `state=prompt` | Codex is at the input prompt waiting for input | Codex auto-fix loops (e.g. test failure → fix → retest) keep state at `session` indefinitely; never hits `prompt` while looping |
| `state=session` | Codex is mid-turn or post-tool-call | Active work AND idle-at-prompt-with-pending-internal-event look identical |
| `IDLE` (pane) | Time since last pane interaction (input typed, **focus event**, etc.) | Resets when user opens the tmux pane to peek. Not a "work idle" measure. |
| `log_mtime` | Last chunk emitted to output log | A finished worker that printed its summary 5 min ago and is now genuinely done at the prompt looks the same as a worker mid-think |
| Session exit | Process gone | Codex never auto-exits — it sits at the prompt forever after task done |

There is no signal that says **"the worker completed the task it was
dispatched for."**

### Real-world failure mode (2026-05-01 → 02 holm overnight chain)

Setup:
- `harnex run codex --id cx-i-380 --tmux ...` for a Tier B implementation.
- Orchestrator (Claude) wrote a poll loop monitoring `state=prompt && IDLE>=45s`
  as the completion signal.
- User went to sleep at ~23:00 IST; orchestrator ran unattended.

Timeline:
- `00:09 IST`: Codex began TDD impl.
- `01:29 IST`: Codex committed the verdict file (Gate 3 verdict `7f42cbf0`) —
  task **done**. Codex left running at the prompt.
- `01:30 → 06:30 IST`: 5-hour idle. Orchestrator's monitor never fired
  because:
  - `state` stayed at `session` (post-task pane state, not `prompt`),
  - `IDLE` was at 5h **but** the orchestrator's completion test required
    `state=prompt` AND idle, so it skipped this branch.
- `07:21 IST`: User opened the tmux pane to check. **Pane focus reset
  `IDLE` to 11s** in `harnex status`. Orchestrator picked this up as a
  state change but still no `state=prompt` match.
- User then prompted the orchestrator directly to learn Gate 3 had
  finished six hours earlier. The next ~6 hours of planned overnight
  work (Plan 381 implementation + 2 documentation dispatches + cleanup)
  did not happen.

**Cost**: roughly 6 hours of unattended productivity, plus user trust.

The orchestrator's completion test was wrong (it should have OR'd in
artifact-existence + commit-age), but the deeper problem is that **harnex
gave it nothing better to OR against.** Every orchestrator authoring
this same test will trip on the same combination of pane signals.

### Why pane focus resets `IDLE`

Worth flagging as a documented quirk: harnex's `IDLE` field measures
time since the last tmux pane event of any kind, including focus
changes. So:

- User switches to the pane to peek at progress → `IDLE` resets to 0.
- A monitor watching `IDLE` infers the worker just did something.
- This made the holm orchestrator's log noisy at 07:21 even though the
  worker had been done for hours.

This is "harnex correctly reporting what it can observe" — the bug is
the field name implies more than it delivers. Either rename
(`PANE_IDLE` vs `WORK_IDLE`) or expose a second column that ignores
focus events.

## Proposal

Two surfaces, both small:

### A. Adapter "task-complete" detection

Codex (and Claude, and any future smart-prompt CLI) already prints a
recognizable final assistant turn after each task: a short summary,
followed by the input prompt re-rendering. Harnex's smart-prompt
adapter for Codex (`lib/harnex/adapters/codex.rb` or similar) can:

1. After detecting the prompt has reappeared post-tool-use, capture the
   last assistant turn's text.
2. Emit a structured event:
   ```json
   {"type":"task_complete","id":"cx-i-380","at":"2026-05-02T01:29:54+0530",
    "last_reply_lines":N,"last_reply_excerpt":"..."}
   ```
3. Expose a `harnex status` column — `LAST_DONE_AT` — that is **set
   only by this event**, never by pane focus or log mtime.

This is a heuristic but a strong one: Codex emits a final summary, then
goes quiet. The combination "prompt re-rendered + ≥X seconds of zero
log growth" is high-signal compared to any single pane field.

### B. Worker-side opt-in: `harnex done` callback

For tasks where the orchestrator wants explicit confirmation, the
dispatch brief can instruct Codex:

> When you have committed the final artifact and the task is complete,
> run `harnex done --id <ID> --artifact <path>` as your last shell
> command before stopping.

`harnex done`:
- Emits a `task_complete` event with `source: "explicit"`.
- Records the artifact path on the session metadata.
- Returns immediately (no side effects on the session itself).

Then `harnex wait --id <ID> --until task_complete` becomes the
canonical "block until task done" primitive — replacing the fragile
`wait --until exit` pattern.

For brief authors, the override is one extra line; for orchestrators,
it eliminates the inference layer entirely.

### C. `harnex wait --until <event>`

Today `harnex wait --id <ID>` blocks until session exit. Codex never
exits, so this is unusable for completion. Generalize to:

```
harnex wait --id <ID> --until exit
harnex wait --id <ID> --until prompt
harnex wait --id <ID> --until task_complete
harnex wait --id <ID> --until "log_idle>=300"
```

Backed by `harnex events --id <ID>`. The orchestrator picks the
predicate; harnex blocks until it fires. No more shell poll loops for
the common case.

## Acceptance

- Adapter emits `task_complete` events for Codex (heuristic) on every
  dispatch; visible in `harnex events`.
- `harnex done` command exists and emits explicit `task_complete`.
- `harnex wait --until task_complete` blocks until the event fires.
- `harnex status` either drops `IDLE` in favor of `WORK_IDLE` (focus-
  insensitive) or adds it as a second column. Documented either way.
- Test: dispatch a Codex session that finishes a task and idles at the
  prompt; `harnex wait --until task_complete` returns within seconds
  of the final reply, regardless of pane focus events.

## Out of scope

- Worker-emitted progress events beyond completion (covered by 23).
- Disconnect detection (covered by 24).
- Multi-task sessions where one Codex pane handles N sequential tasks —
  out of scope for this issue; would need explicit `harnex done` per
  task.

## Related

- `22_built_in_dispatch_monitoring.md` — log-mtime + bounded resume
  (fixed). This issue is the missing positive signal alongside that
  negative-signal work.
- `24_disconnect_detection.md` — distinguishes "stalled" from "thinking"
  using log mtime; orthogonal but compatible.
