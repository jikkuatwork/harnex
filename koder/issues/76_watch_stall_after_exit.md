---
status: resolved
priority: P3
created: 2026-10-16
updated: 2026-10-18
tags: watch, observer, stalls
issue_kind: slice
type: feature
---

# Issue 76 — `watch --stall-after DUR` with a distinct exit code

Split from #75 ("Also observed"). In Holm Queue 156 a Pi session
(`pi-q156-r1`) showed `model_active: true` with `model_idle_s` ~1,600 and
`tool_idle_s` ~3,000 while `work_state` stayed `running`. `watch` had no exit
for that shape, so the Holm supervisor now polls `activity.model_idle_s`
itself.

Proposal: an opt-in `watch --stall-after DUR` that exits with a code distinct
from timeout (124) when the structured activity clocks show no model/tool
progress for `DUR`, without stopping the worker. Open questions before
planning: which clock(s) define a stall for PTY vs structured adapters (PTY
clocks are unknown), interaction with `run --stall-after` force-resume, and
the exit-code number.

## Decisions (owner, 2026-10-18)

The open questions above are resolved:

1. **Structured clock (Pi; Codex app-server shares it):** a stall is no
   observed progress for `DUR`, where progress is the most recent of turn start,
   any model event, and any tool event (`min(turn_age_s, model_idle_s,
   tool_idle_s)` from the status `activity` block). It counts only while
   `activity.turn_active` is true and work is not settled. A command that stays
   silent longer than `DUR` also counts, which catches hung commands; callers
   pick `DUR` above their longest quiet build or test.
2. **PTY adapters** (no structured clocks): fall back to `log_idle_s`
   (transcript freshness). The result labels which clock fired:
   `clock: activity|output_log`. This is conservative because TUIs redraw
   spinners and timers.
3. **`run --watch --stall-after` stays independent.** `watch --stall-after` only
   observes and exits; it never nudges or stops the worker. `run --watch` keeps
   its output-log nudge. If both run, set watch's `DUR` above run's
   `stall-after × (max-resumes + 1)`.
4. **Exit code 4** (`stalled`), next to 0/1/2/3/124 in the `wait --until done`
   contract. No markers are written and `--stop-on-terminal` does not apply,
   the same as a timeout.

The predicate lives in one shared module so #77's `stalled` event can reuse it.

## Resolution

Implemented 2026-10-18 per the decisions above.

- `harnex watch --stall-after DUR` and `harnex wait --until done --stall-after
  DUR` (`wait` rejects the flag for other predicates). The status API is polled
  every `min(max(DUR/4, 0.5s), 15s)`. On a stall the command prints
  `{status: "stalled", wait_result: "stalled", work_state: "running",
  stall: {clock, idle_s, threshold_s}}`, exits **4**, and leaves the worker
  running. Watch writes no marker and skips `--stop-on-terminal`.
- `Harnex::Stall` (`lib/harnex/stall.rb`) is the shared predicate: `activity`
  clock = `min(turn_age_s, model_idle_s, tool_idle_s)` during an active turn;
  `output_log` clock = `log_idle_s` for PTY; nil for settled work or an
  inactive structured turn. #77 can reuse it.
- `run --watch` is unchanged; usage and `guides/04_monitoring.md` document the
  relationship and the exit code.

Verification: `test/harnex/stall_test.rb` and
`test/harnex/commands/wait_stall_test.rb` (structured stall → 4, below
threshold → keeps waiting to done, PTY fallback, flag validation, watch with
no marker and no stop). Live on Pi 1.3.0 (checkout): a dispatch running a
silent `sleep 45` tripped `watch --stall-after 20s` at 24s (`clock=activity`;
Pi emits no tool events during a silent command) with the worker still busy;
a follow-up `watch` returned 0 when the turn completed.
