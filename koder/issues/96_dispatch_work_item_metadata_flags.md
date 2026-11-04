---
status: open
priority: P2
created: 2026-11-04
updated: 2026-11-04
tags: delegate, ask, telemetry, dispatch, process-review
type: feature
related: 86, 95
---

# Issue 96 — dispatch rows cannot be tied to the work item they serve

## What happened (downstream overnight queue, 2026-11-03/04)

A downstream project ran 14 delegate lanes and about 30 read-only asks overnight. Every
`dispatch.jsonl` row already records rich actuals (duration, tokens, cost, LOC, changed paths,
commit, outcome, stop reason), but the work-item fields are always empty:

```json
"tier": null,
"queue": {"project_id": null, "queue_id": null, "entry_id": null, "entry_title": null,
          "issue": null, "plan": null, "phase": "delegate", "tier": null, "intent": "delegate"},
"predicted": {}
```

`harnex delegate`, `ask` and `reply` expose no flags to set them, so a process review cannot
join a lane or an ask to its queue row, plan or issue, or compare predicted with actual time,
without parsing the project's prose logs by hand. Asks land only in the global stream, and their
answers only in `output/<id>.log`.

## Ask

1. Flags on `delegate`, `ask` and `reply` (and the MCP tools): `--queue ID`, `--entry ID`
   (row, e.g. `S12b`), `--round N`, `--plan ID`, `--issue ID`, `--tier T`, `--predicted-min N`,
   filling the existing `queue.*`, `tier` and `predicted` fields; a reply inherits the lane's
   values unless overridden.
2. For asks, record the answer's verdict line (first line) and the output-log path in the
   dispatch row, and also write the row to the repo stream when `--cwd` is inside a repo that
   has a `.harnex/` directory (opt-in flag is fine).
3. Document the fields in `harnex agents-guide` so orchestrators set them by habit.

## Why

Projects want astra/Fable-style process reviews ("which gate caught what, where time goes");
harnex already measures the actuals — it only lacks the join keys.
