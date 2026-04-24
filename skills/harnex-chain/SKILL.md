---
name: harnex-chain
description: End-to-end workflow from issue to shipped plans via harnex agents. Covers mapping, plan extraction, and the serial plan -> review -> implement -> review -> fix loop.
---

# Chain Implement

Take an issue from design through to shipped code via harnex agents. This
skill defines chain semantics (phase order, quality gates, escalation), while
spawn/watch/stop mechanics come from `harnex-dispatch`.

## Orchestrator Role

- Claude is the orchestrator only: dispatches sessions, watches progress,
  decides stop/resume/escalate, and enforces phase gates.
- Codex performs all production work: plan writing, plan reviews,
  implementation, code reviews, and fixes.
- The orchestrator does not implement or review directly except emergency
  intervention to recover a blocked chain.

## Guiding Principle

Keep each agent invocation inside its safe context zone (< 40% of context
window). Large issues should be split into smaller plans so each worker has a
narrow, testable scope.

Scale to the issue size:
- Small issue: skip mapping, one plan, one serial loop.
- Medium issue: one phased plan is usually enough.
- Large issue: mapping plus extracted thin-layer plans.

## Workflow Overview (Serial Default)

```
Issue (user + orchestrator chat)
  ↓
[Mapping Plan] -> [Map Review] -> [Fix Map]     <- optional for large scope
  ↓
[Plan Extraction] -> thin-layer plans            <- optional if one plan suffices
  ↓
Per plan (serial on main):
  Plan -> Plan Review -> Fix Plan
    -> Implement -> Code Review -> Fix Code
    -> Commit -> next plan
```

The serial loop is the default path. For each step, use `harnex-dispatch`
Fire & Watch for lifecycle operations, including stop timing in
`skills/harnex-dispatch/SKILL.md#3-stop`.

## Phase 1: Issue

User and orchestrator converge on a concrete issue document
(e.g., `koder/issues/NN_label/INDEX.md`) with:
- Problem and motivation
- Design decisions and trade-offs
- Acceptance criteria
- Open questions

## Phase 2: Mapping Plan (Optional)

Use when scope is broad, has sequencing constraints, or still contains
user-blocking questions. Skip for small, coherent issues.

Outputs:
- Technical map of files/functions/seams
- Sequencing constraints
- Explicit user-blocking questions

Gate:
- If map review finds user-blocking questions, stop the chain and return to
  user.

## Phase 3: Plan Extraction (Optional)

Use when the mapping plan should be decomposed into thin-layer plans.
Each extracted plan must be one independently testable capability and ordered
by dependency.

## Phase 4: Serial Plan Loop (Default)

Per plan:
1. Plan (Codex)
2. Plan Review (Codex)
3. Fix Plan (Codex) when review finds issues
4. Implement (Codex)
5. Code Review (Codex)
6. Fix Code (Codex) when review finds issues
7. Commit and advance to next plan

Gating rules:
- Do not start implementation with unresolved P1 plan-review findings.
- Do not advance to the next plan with unresolved P1 code-review findings.
- Keep plan-fix and code-fix loops active until the review gate passes.

## Parallel Variant

Parallelism is allowed only for planning passes. Keep implementation serial
on `main` unless the user explicitly requests worktrees.

Approved parallel lanes:
- Parallel plan-writing sessions (one plan file per Codex session)
- Parallel plan-review sessions (one review file per Codex session)

Capacity rule:
- Run at most 5 concurrent Codex sessions total across all active lanes
  (global cap, not per lane).

Lifecycle rule:
- Use `harnex-dispatch` Fire & Watch for spawn/watch mechanics.
- Stop timing is defined in `skills/harnex-dispatch/SKILL.md#3-stop`.
- Stop each completed session as soon as its commit lands.

Implementation rule:
- Serial implementation on `main` is the default.
- Parallel implementation is allowed only with explicit user request and
  worktree isolation (see `harnex-dispatch` worktree guidance).

## Failure and Escalation

- User-blocking question in plan/map review: stop and ask user; do not guess.
- Review returns P1: dispatch the corresponding fix step and re-review.
- Implementation diverges materially from plan: stop and re-plan.
- Worker is stuck or blocked by prompt/dialog: intervene, then continue with a
  fresh worker if needed.

## Naming Conventions

Use stable IDs per step, with fresh sessions per step (no session reuse):
- Mapping: `cx-map-NN`
- Map review: `cx-rev-map-NN`
- Map fix: `cx-fix-map-NN`
- Plan write: `cx-plan-NN`
- Plan review: `cx-rev-plan-NN`
- Plan fix: `cx-fix-plan-NN`
- Implement: `cx-impl-NN`
- Code review: `cx-rev-NN`
- Code fix: `cx-fix-NN`

For run/watch/stop command patterns, use `harnex-dispatch` directly.
