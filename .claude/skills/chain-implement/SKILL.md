---
name: chain-implement
description: End-to-end workflow from issue to shipped plans via harnex agents. Covers mapping, plan extraction, and the serial plan → review → implement → review → fix loop.
---

# Chain Implement

Take an issue from design through to shipped code via harnex agents. Designed
so the user can walk away after triggering the chain.

## Guiding Principle

Keep each agent invocation inside its **safe context zone** (< 40% of context
window). Agents produce their smartest work when they aren't overloaded. Large
issues get split into smaller plans because massive plans degrade agent output.

**Scale the process to the work:**
- Small issue, one coherent change → skip mapping, write one plan, implement
- Medium issue, a few moving parts → one plan with phases is fine
- Large issue, many files/seams/sequencing → mapping plan + extracted plans

The phases below describe the **full** workflow. Skip phases that aren't needed.

## Workflow Overview

```
Issue (user + agent chat)
  ↓
[Mapping Plan] → [Map Review] → [Fix Map]     ← skip if scope is small
  ↓
[Plan Extraction] → thin-layer plans           ← skip if one plan suffices
  ↓
Per plan (serial):
  Plan (codex) → Plan Review (claude) → Fix Plan (codex)
    → Implement (codex) → Code Review (claude) → Fix Code (codex)
    → Commit → next plan
```

### Why two review phases?

The plan review catches design problems before code is written. The code review
catches implementation problems after. Skipping plan review leads to wasted
implementation cycles when the plan itself is flawed. This was validated in
production — adversarial plan/review cycles consistently produce better outcomes
than jumping straight to implementation.

## Phase 1: Issue

The user and the agent have a detailed design chat. From that, a structured
issue is filed (e.g., `koder/issues/NN_label/INDEX.md`).

The issue captures:
- The problem and motivation
- Design decisions and trade-offs
- Acceptance criteria
- Known open questions

This phase is interactive — the user is present and driving.

## Phase 2: Mapping Plan (optional — for large issues)

Skip if the issue is small enough for a single implementation plan. Use when
the scope crosses many files, involves sequencing constraints, or has open
design questions that would block an away user.

A **mapping plan** doesn't produce code. It produces a detailed technical map:
- Exact files, functions, and seams involved
- Sequencing constraints (what depends on what)
- Questions that need user input before implementation

### Why mapping is its own phase

- **Surfaces blockers early** — user-blocking decisions come out here, not
  halfway through implementation
- **Creates shared context** — the mapping plan becomes the reference for all
  subsequent plans
- **Separates research from decomposition** — mapping agent focuses on
  understanding, extraction focuses on scoping

### Dispatch

```bash
harnex run codex --id cx-map-NN --tmux cx-map-NN \
  --context "Write a mapping plan for koder/issues/NN_label/INDEX.md. \
Produce a detailed technical map: files, seams, sequencing, open questions. \
Write to koder/plans/NN_mapping.md."
```

Poll every 30s with `harnex pane --id cx-map-NN --lines 20`.

### Map Review

```bash
harnex run claude --id cl-rev-map-NN --tmux cl-rev-map-NN \
  --context "Review koder/plans/NN_mapping.md. Check: unresolved user questions? \
Accurate file/function analysis? Sequencing constraints identified? \
Write review to koder/reviews/NN_mapping.md"
```

**If user-blocking questions exist**, stop the chain and surface them.

## Phase 3: Plan Extraction (optional)

Skip if the mapping plan describes one coherent change, or if you skipped
mapping entirely.

Extract thin-layer implementation plans from the mapping plan. Each plan is:
- **One capability** — testable independently
- **Self-contained** — the implementing agent reads only that plan file
- **Ordered** — respects sequencing constraints from the mapping plan

```bash
harnex run codex --id cx-extract-NN --tmux cx-extract-NN \
  --context "Read koder/plans/NN_mapping.md. Extract thin-layer plans. \
Each plan is one independently testable capability. Write to koder/plans/."
```

## Phase 4: Serial Plan Loop

Each plan goes through the full cycle. This is the walk-away part.

### Per-plan cycle

```
1. Plan (codex)        — write/refine the plan if not already extracted
2. Plan Review (claude) — check plan against codebase, flag issues
3. Fix Plan (codex)    — address review findings
4. Implement (codex)   — write code, run tests, commit per phase
5. Code Review (claude) — review implementation against plan
6. Fix Code (codex)    — address review findings if needed
7. Commit              — final state on master
8. → next plan
```

Steps 1-3 can be skipped if the plan was already extracted and reviewed during
the mapping phase, or if the issue is simple enough that the plan is obviously
correct.

### Dispatch pattern

For each plan NN, use the Fire & Watch pattern from the `dispatch` skill:

```bash
# Steps 1-3: Plan convergence (skip if plan already extracted and reviewed)
harnex run codex --id cx-plan-NN --tmux cx-plan-NN \
  --context "Refine koder/plans/NN_label.md based on current codebase state."
# Poll every 30s: harnex pane --id cx-plan-NN --lines 20
# When done: harnex stop --id cx-plan-NN

harnex run claude --id cl-rev-plan-NN --tmux cl-rev-plan-NN \
  --context "Review koder/plans/NN_label.md. Check: accurate file/function refs? \
Sequencing correct? Acceptance criteria testable? \
Write review to koder/reviews/NN_label.md"
# Poll → stop → if NEEDS FIXES, dispatch cx-fix-plan-NN

# Step 4: Implement
harnex run codex --id cx-impl-NN --tmux cx-impl-NN \
  --context "Implement koder/plans/NN_label.md. Run tests when done. Commit after each phase."
# Poll every 30s: harnex pane --id cx-impl-NN --lines 20
# When done: harnex stop --id cx-impl-NN

# Steps 5-6: Code review + fix
harnex run claude --id cl-rev-NN --tmux cl-rev-NN \
  --context "Review implementation of plan NN against koder/plans/NN_label.md. \
Write review to koder/reviews/NN_label.md"
# Poll every 30s: harnex pane --id cl-rev-NN --lines 20
# When done: harnex stop --id cl-rev-NN
# If NEEDS FIXES → dispatch cx-fix-NN
# If PASS → next plan

# Fix (if needed)
harnex run codex --id cx-fix-NN --tmux cx-fix-NN \
  --context "Fix findings in koder/reviews/NN_label.md for plan NN. Run tests. Commit."
# Poll, stop, re-review if needed
```

### Poll cadence

Checking is cheap — 20 lines is a few hundred bytes:

| Elapsed | Interval | Rationale |
|---------|----------|-----------|
| 0–2 min | 30s | Catch fast completions and early errors |
| 2–10 min | 60s | Steady state for typical work |
| 10+ min | 120s | Long-running, reduce noise |

```bash
harnex pane --id cx-impl-NN --lines 20
```

### Naming conventions

| Step | ID pattern | Example |
|------|-----------|---------|
| Mapping plan | `cx-map-NN` | `cx-map-42` |
| Map review | `cl-rev-map-NN` | `cl-rev-map-42` |
| Plan extraction | `cx-extract-NN` | `cx-extract-42` |
| Plan write/refine | `cx-plan-NN` | `cx-plan-184` |
| Plan review | `cl-rev-plan-NN` | `cl-rev-plan-184` |
| Plan fix | `cx-fix-plan-NN` | `cx-fix-plan-184` |
| Implement | `cx-impl-NN` | `cx-impl-184` |
| Code review | `cl-rev-NN` | `cl-rev-184` |
| Code fix | `cx-fix-NN` | `cx-fix-184` |

**Rule**: Fresh instance per step. Don't reuse agents across steps — clean
context avoids bleed.

## Worktree Option

By default, all work happens serially on master. Use worktrees only when:
- The user explicitly requests isolation
- You need to work on something else while a plan is being implemented

See the `dispatch` skill for worktree setup and caveats.

## When Things Go Wrong

**Plan review finds user-blocking question**: Stop the chain. Surface the
question. Resume after the user answers. This is exactly what the plan review
phase is for — catching these before implementation begins.

**Plan review finds P1**: Dispatch a plan fix agent (`cx-fix-plan-NN`).
Re-review the plan. Do not proceed to implementation with unresolved P1s.

**Code review finds P1**: Dispatch a code fix agent (`cx-fix-NN`). Re-review
after fix. Do not skip to the next plan with unresolved P1s.

**Implementation diverges from plan**: The implementer may discover the plan
is wrong. If the divergence is minor (P3), note it and continue. If major,
stop and re-plan.

**Agent gets stuck**: Check `harnex pane --lines 20`. If blocked on a
permission prompt or trust dialog, intervene. If confused, stop the agent and
dispatch a fresh one with clearer instructions.
