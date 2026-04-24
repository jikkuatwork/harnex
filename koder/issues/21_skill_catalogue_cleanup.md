---
id: 21
title: "Harnex skill catalogue cleanup — collapse, clarify orchestrator role, cover parallel"
status: open
priority: P2
created: 2026-04-24
---

# Issue 21: Harnex Skill Catalogue Cleanup

## Problem

Four harnex-* skills load globally into every Claude session:

- `harnex`
- `harnex-dispatch`
- `harnex-chain`
- `harnex-buddy`

Three issues with the current shape:

### 1. `harnex` overlaps with `harnex-dispatch`

`harnex`'s description is generic ("collaborate, spawn, coordinate, relay
instructions, multi-agent work") and substantially overlaps with
`harnex-dispatch` (which owns the spawn/watch/stop lifecycle). In practice the
generic skill adds description noise without adding distinct capability — when
a user says "dispatch codex", it is unambiguous; when they say "send a message
to codex", both skills plausibly apply.

### 2. `harnex-chain` assumes serial-only workflow

`harnex-chain` describes the end-to-end issue → plans loop as a **serial**
"plan → review → implement → review → fix" flow. Real sessions now routinely
run N plan-writes and N plan-reviews in parallel (up to 5 concurrent per Azure
throttling). No skill owns "parallel within chain," so the orchestrator
improvises — which is where subtle discipline misses happen (e.g. leaving
committed sessions at prompt, starving stragglers of Azure capacity).

### 3. Orchestrator role is implicit

Claude-as-orchestrator / Codex-does-all-work is the primary operating mode but
lives only in private user memory, not in the skill docs. A fresh session has
to rediscover the role boundary from context. Codifying it in `harnex-chain`
would remove that ambiguity.

## Proposed Fix

### A. Collapse `harnex` into `harnex-dispatch`

Remove the generic `harnex` skill. Fold any unique content (if any) into
`harnex-dispatch`. `harnex-dispatch` is already the precise, correct home for
spawn/watch/stop.

### B. Rewrite `harnex-chain`

1. Add an **Orchestrator Role** section at the top: Claude dispatches,
   watches, stops, resumes, decides. Codex writes everything (plans, reviews,
   code, fixes). No implementation or review by the orchestrator.
2. Keep the existing serial flow as the default.
3. Add a **Parallel Variant** section covering:
   - When to parallelize (plan-writing, plan-reviewing — both read-mostly,
     commit one file each)
   - 5-concurrent Codex cap (Azure throttling)
   - Per-session lifecycle still applies — reference `harnex-dispatch`'s
     "stop each session the moment its commit lands" rule
   - Implementation remains serial on master; parallel only with worktrees
     on explicit request
4. Trim duplicated spawn/watch/stop mechanics — delegate to
   `harnex-dispatch` by reference.

### C. Keep `harnex-buddy` as-is

Narrow purpose, no overlap, fine.

## Acceptance

- [ ] `harnex` skill removed (or reduced to a pointer at `harnex-dispatch`)
- [ ] `harnex-chain` has explicit Orchestrator Role section
- [ ] `harnex-chain` has Parallel Variant section with 5-concurrent cap and
      stop-early discipline
- [ ] Global skill catalogue for a fresh session shows 3 harnex skills
      (dispatch, chain, buddy), not 4

## Context

Raised after a session that ran N plan-writes and N plan-reviews in parallel
against a single mapping. The orchestrator left committed sessions at prompt
instead of stopping them promptly, prolonging Azure throttling on the
stragglers. Root cause: parallel-within-chain isn't owned by any skill, so
the serial chain mental model and the single-session dispatch mental model
collided. A precision rewrite of `harnex-dispatch` captured the stop-early
rule for the single-session case; `harnex-chain` needs an analogous refresh
for the multi-session case.
