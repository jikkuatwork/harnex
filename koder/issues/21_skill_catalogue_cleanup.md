---
id: 21
title: "Skill catalogue cohesion — design the harnex skills as a coordinated set"
status: open
priority: P2
created: 2026-04-24
---

# Issue 21: Skill Catalogue Cohesion

## Problem

`harnex skills install` copies skills into `~/.claude/skills/`, so every
installed user gets the full set loaded into every Claude session at once.
That means the skills are not four independent docs — they are **one
coordinated catalogue** that must work ideally together.

The current set ships four skills:

- `harnex`
- `harnex-dispatch`
- `harnex-chain`
- `harnex-buddy`

As a coordinated set, three cohesion problems:

### 1. `harnex` overlaps with `harnex-dispatch`

`harnex`'s description is generic ("collaborate, spawn, coordinate, relay,
multi-agent work") and substantially overlaps with `harnex-dispatch` (which
owns the spawn/watch/stop lifecycle). Two skills plausibly apply to the same
user intent. In a coordinated catalogue, each skill's description should
disambiguate itself from the others on sight.

### 2. `harnex-chain` assumes serial-only workflow

`harnex-chain` describes the end-to-end issue → plans loop as a serial
"plan → review → implement → review → fix" flow. Real sessions now routinely
run N plan-writes and N plan-reviews in parallel (up to 5 concurrent per
Azure throttling). No skill owns "parallel within chain," so the
orchestrator improvises — which is where subtle discipline misses happen
(e.g. leaving committed sessions at prompt, starving stragglers of Azure
capacity).

### 3. Orchestrator role is implicit

Claude-as-orchestrator / Codex-does-all-work is the primary operating mode
but isn't stated in any skill. A fresh session has to rediscover the role
boundary from context. Codifying it in `harnex-chain` would make the role
visible the moment the skill is needed.

## Design Goal

The catalogue a user sees after `harnex skills install` should satisfy:

- **No overlap** — each skill has one clear job; no two descriptions
  plausibly match the same intent.
- **Explicit cross-references** — when one skill's flow references another's
  mechanics (e.g. chain → dispatch's spawn/watch/stop), say so by name
  instead of duplicating prose. Duplication drifts.
- **Role-aware** — Claude and Codex responsibilities are stated once, in the
  skill where they most matter (`harnex-chain`), and referenced from others.
- **Minimum surface** — fewer skills if the same coverage can be reached. The
  list itself is prompt budget.

## Proposed Fix

### A. Collapse `harnex` into `harnex-dispatch`

Remove the generic `harnex` skill. Fold any unique content into
`harnex-dispatch`. `harnex-dispatch` already owns spawn/watch/stop.

### B. Rewrite `harnex-chain`

1. Add an **Orchestrator Role** section at the top: Claude dispatches,
   watches, stops, resumes, decides. Codex writes everything (plans,
   reviews, code, fixes). The orchestrator does not implement or review.
2. Keep the existing serial flow as the default.
3. Add a **Parallel Variant** section covering:
   - When to parallelize (plan-writing, plan-reviewing — both read-mostly,
     one file each).
   - The 5-concurrent Codex cap (Azure throttling).
   - Per-session lifecycle still applies — reference `harnex-dispatch`'s
     "stop each session the moment its commit lands" rule rather than
     repeating it.
   - Implementation stays serial on master; parallel only with worktrees
     on explicit request.
4. Trim duplicated spawn/watch/stop mechanics — delegate to
   `harnex-dispatch` by reference.

### C. Keep `harnex-buddy` as-is

Narrow purpose, no overlap, fine as a coordinated-set member.

### D. Cross-reference audit

After the rewrite, verify every mechanic appears in exactly one skill and
every skill that needs it links to the canonical location by skill name.

## Acceptance

- [ ] `harnex` skill removed (or reduced to a pointer at `harnex-dispatch`)
- [ ] `harnex-chain` has an explicit Orchestrator Role section
- [ ] `harnex-chain` has a Parallel Variant section with the 5-concurrent
      cap and stop-early discipline
- [ ] After `harnex skills install`, the catalogue shows 3 harnex skills
      (dispatch, chain, buddy), not 4
- [ ] No mechanic is duplicated across skills — each lives in one skill and
      is referenced by name from the others

## Context

Raised after a session that ran N plan-writes and N plan-reviews in
parallel against a single mapping. The orchestrator left committed sessions
at prompt instead of stopping them promptly, prolonging Azure throttling on
the stragglers. Root cause: parallel-within-chain isn't owned by any skill,
so the serial chain mental model and the single-session dispatch mental
model collided. A precision rewrite of `harnex-dispatch` captured the
stop-early rule for the single-session case; `harnex-chain` needs an
analogous refresh for the multi-session case.
