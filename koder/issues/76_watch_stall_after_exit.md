---
status: open
priority: P3
created: 2026-10-16
updated: 2026-10-16
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
