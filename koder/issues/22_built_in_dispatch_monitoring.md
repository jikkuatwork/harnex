---
status: fixed
priority: P2
created: 2026-04-29
resolved: 2026-04-29
tags: monitoring,dispatch,orchestration
---

# Issue 22: Built-in Dispatch Monitoring (log-mtime activity + bounded auto-resume)

## The Problem

Every orchestrator that runs `harnex run codex` ends up writing the same
~50-line shell loop to monitor the dispatch:

- poll commit count + dirty files + `harnex status` every 60s
- detect stall, send `harnex send --force --message "resume"`, cap attempts
- detect completion (commit lands + clean tree + session exited)
- detect silent failure (session exited with no commit)
- decide whether log activity counts as "alive"

This loop is small but full of subtle traps. Three traps hit a holm
session on 2026-04-29 in a single 30-minute window:

1. **State-change-as-stall is too coarse.** Tracking
   `commits/dirty/alive` triggers "stall" when Codex is mid-test-gate
   (e.g. `go test ./... -count=3`). The gate is *active work* but
   produces no state change to the orchestrator's view. First monitor
   force-resumed twice during a passing test gate.
2. **Three-minute stall threshold is too short for impl phases.**
   Calibrated for plan/review where 3 min idle is genuinely stalled. In
   impl, file reading + test running + thinking can legitimately consume
   5–10 min between visible state deltas.
3. **One-shot agent ≠ loop.** Subagents (Claude `Agent` tool) fire the
   prompt once and return — they don't naturally stay in a polling loop
   even when the prompt says "every 60 seconds." Each orchestrator
   stack rediscovers this.

The right activity signal is the harnex output log mtime — it advances
every time Codex emits a chunk (assistant turn, tool call, tool
result). Log mtime > N seconds old + alive = genuine stall.

## Proposal

Promote dispatch monitoring from "external shell loop" to first-class
harnex feature. Two complementary surfaces:

### A. `harnex events --id <ID>` — structured event stream

Emit JSON-line events for any subscriber. Each line a single event:

```jsonl
{"ts":"...","id":"cx-i-242","type":"started","pid":416925}
{"ts":"...","id":"cx-i-242","type":"log_active","age_s":0}
{"ts":"...","id":"cx-i-242","type":"log_idle","age_s":300}
{"ts":"...","id":"cx-i-242","type":"send","msg":"resume","forced":true}
{"ts":"...","id":"cx-i-242","type":"exited","code":0}
```

Composes with existing tools: `harnex events --id X | jq` or pipe into
the orchestrator's own monitor. Removes the need to re-implement polling.

### B. `harnex run codex --watch --stall-after 8m --max-resumes 1`

A built-in babysitter equivalent to the current external loop:

- Watches log mtime every 60s
- Force-resumes when log idle ≥ `--stall-after`, up to `--max-resumes`
- Exits the watcher (not the dispatch) on completion or escalation
- Optionally emits to `--events-fifo /tmp/cx-i-242.events` for the
  orchestrator to subscribe alongside

Phase-aware presets simplify the call:

```bash
harnex run codex --watch --preset impl   # 8m stall, 1 resume
harnex run codex --watch --preset plan   # 3m stall, 2 resumes
harnex run codex --watch --preset gate   # 15m stall, no resume
```

The presets become the canonical place to encode hard-won timing
knowledge — currently scattered across multiple project knowledge bases
and human memory.

## Why now

This session (holm 2026-04-29 — Issue 242 fix) hit all three traps in
the first 10 minutes. Pattern is consistent across every dispatch I've
run; every orchestrator I've built reinvents the same loop.

Cost of the feature: ~200 lines of Ruby in harnex.
Cost of NOT having it, per dispatch: ~50 lines of shell + a 2-iteration
debug pass when the first monitor over-fires (this session burned ~20
min).

## Out of scope (capture for later)

Other gaps noticed in the same session, lower priority:

- **Brief validation gate.** `harnex run codex --brief X.md` could fail
  the dispatch if the brief lacks the four depth-bound levers (prior
  digestion, read budget, output ceiling, override path). Mirrors
  `task-brief-discipline.md` from holm-side workflows.
- **Structured result extraction.** Workers are asked to end with a
  structured summary block. Harnex could parse that out as JSON
  (`harnex result --id X`) so orchestrators don't have to scrape the
  pane.
- **Tier-aware shorthand.** `harnex run-tier-c --id X --brief Y.md`
  bundles dispatch + watch with the right preset for Tier C work.

These can be separate issues if/when the patterns repeat.
