---
status: open
priority: P2
issue_kind: track
created: 2026-07-15
updated: 2026-07-15
tags: conveyor,queue,coordinator,orchestration,runner,determinism
---

# Issue 59 — Deterministic conveyor runner: mechanical queue drain, model-only judgment

## Problem

In blind queue runs, the coordinator is currently a model session that performs
almost entirely mechanical work: read the queue file, pick the next row,
dispatch a worker, wait on a fence, validate the receipt, check Git identity,
enforce fix-cycle caps and circuit breakers, batch run-log/metadata updates,
roll over at a cap, and close at a stop gate.

SDK Queue `#002` evidence
(`~/Projects/holmhq/sdk/koder/analysis/001_q002_orchestration_efficiency/INDEX.md`):

- coordinator sessions consumed ~10.7M accounted tokens — **~49% of the run**
  — against ~11.2M for all implementation/review/fix workers combined;
- 6 coordinator dispatches were needed for 2.5 completed rows (4 existed only
  to recover adapter churn);
- 10 of 20 commits were process/checkpoint-only;
- the run could not close unattended: the blocked-close/statistics step waited
  ~3h44m for the interactive session to resume.

The rules a coordinator follows are already written as prose state machines in
koder-pattern (`references/queues/*.md`) — fence durations, two-attempt
breakers, receipt-before-signal ordering, rollover caps. Prose interpreted by a
model is the wrong medium for deterministic control flow: it is expensive,
drifts, and resets its own guarantees whenever context rotates.

## Goal

A `harnex conveyor` (name open) that drains a declarative queue file using
existing primitives (`run`, `wait`, `send`, artifact reports, dispatch
history), where:

1. **The runner owns mechanics.** Row selection, phase sequencing
   (implement → review → fix cycles up to a cap), monitor fences, breaker
   counting (consuming #57 outcome classes), receipt/typed-report validation,
   Git commit-identity verification (`git rev-parse`, clean-tree checks),
   run-log/journal appends, rollover, and stop-gate close (commit/push hook,
   optional close script) are deterministic code.
2. **Models own judgment.** The runner dispatches workers for implementation,
   review, and fixes, and may dispatch a *coordinator-on-exception* model only
   when judgment is required: findings triage, blocker classification,
   ambiguous receipts, or an explicit `escalate` row flag.
3. **Owner gates are hard.** The queue file declares stop gates and forbidden
   actions; the runner halts at them and never widens scope. Unattended close
   (checkpoint commit, state file update, statistics emit) is a first-class
   terminal step so a blocked 2 a.m. run does not idle until morning.

The queue file should carry per row: phase sequence, adapter/model per phase,
task/brief path, validation command(s), fix-cycle cap, fence/cap durations,
and proof requirements — roughly what koder-pattern queue frontmatter already
records, made machine-readable.

## Why Harnex

Harnex already owns dispatch, fences, receipts, queue attribution (#47), typed
sidecars (#52), and history. The conveyor is a loop over those primitives.
#55 deliberately excluded "the durable queue conductor itself" from telemetry
scope; this issue is that conductor.

## Acceptance criteria

- [ ] A queue file format (versioned schema) expressing rows, phases,
      adapters, validation commands, caps, fences, stop gates.
- [ ] `conveyor --dry-run` prints the full drain plan without dispatching.
- [ ] Single-row drain: implement → review → conditional fix cycles, with
      receipt validation and Git identity checks performed by the runner.
- [ ] Breakers/budgets consume #57 outcome classes; breach halts with a
      machine-readable reason.
- [ ] Unattended terminal step: checkpoint commit + configurable close hook +
      statistics emission without a live interactive session.
- [ ] Coordinator-model dispatch happens only on declared exception paths, and
      each escalation is a normal, attributed dispatch row.
- [ ] A resumed conveyor reconciles from dispatch history + Git, not from
      model memory.

## Out of scope

- Replacing koder-pattern's durable artifacts (issues/plans/reviews stay
  human/model-authored Markdown; the queue file may be generated from them).
- Review judgment, finding severity, or acceptance decisions.
- Multi-repo or parallel-worktree ownership (serial single-repo first).

## Relationship to existing work

- Consumes #56 (preflight gate before launch), #57 (outcome classes/budgets),
  #52 (typed validation sidecars), #47 (queue attribution), #55 (run identity
  and orchestration-tax measurement of whatever primary remains).
- koder-pattern (`~/Projects/pi`) will slim its prose state machines to point
  at this runner as the mechanical authority once it exists.

## Triage

- **Tier**: A/B design track; converge the queue-file contract in a plan
  before implementation.
- **Risk**: medium/high — this changes the operating model of blind runs;
  mitigated by dry-run first and per-slice delivery.
- **First useful slice**: queue-file schema + `--dry-run` + single-row drain
  with receipt/Git validation and manual continue.
