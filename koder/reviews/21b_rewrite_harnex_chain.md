# Review: Plan 21B — Rewrite `harnex-chain` Skill

Reviewer: cl-rev-plan-21b
Date: 2026-04-24
Verdict: **PASS WITH CAVEATS** — plan is sound and scope-correct; one
load-bearing external assumption needs to be named explicitly.

## Summary

The plan maps cleanly onto Issue #21's Unit B (Section B of "Proposed
Fix"). The target outcomes, phases, draft outline, and validation
checklist all correspond to the acceptance criteria in the issue. Scope
is correctly drawn around `skills/harnex-chain/SKILL.md` only and
explicitly defers Unit A and Unit C.

## Coverage against the brief

### Orchestrator Role section (Claude dispatches, Codex writes)

Specified clearly. Plan §"Target outcomes" and Phase 1 both state:

- Claude orchestrates only (dispatch/watch/stop/resume/decide)
- Codex performs all production work (plans, reviews, code, fixes)
- Orchestrator does not implement or review directly

Phase 1 is concrete enough to execute: new `## Orchestrator Role`
heading right after the intro, imperative role lines, plus an explicit
prohibition. Matches Issue #21 §"Role-aware" and §B.1. **OK.**

### Parallel Variant — 5-concurrent cap

Phase 2.4 and §"Target outcomes" both call out the 5-session cap with
the Azure throttling reason. Plan-writes and plan-reviews are named as
the two approved parallel lanes, matching Issue #21 §B.3. **OK.**

### Parallel Variant — stop-on-commit discipline

Phase 2.5 states "Stop each completed session as soon as its commit
lands" and requires referencing `harnex-dispatch` rather than
duplicating lifecycle prose. Matches issue §B.3 second bullet. **OK in
intent**, but see Risk 1 below — the referenced rule may not be
prominent enough in the current `harnex-dispatch` text.

### Parallel Variant — worktrees only on explicit request

Phase 2.6 and Target outcomes both pin this: "serial implementation on
master by default; parallel implementation only when user explicitly
requests worktrees (reference dispatch worktree section)". The current
`harnex-chain` already contains a "Worktree Option" block that states
this default; the plan correctly promotes the rule into the parallel
section too. **OK.**

### Duplicated spawn/watch/stop mechanics trimmed

Phase 3 calls for removing duplicated command blocks and poll-cadence
tables and replacing them with named references to `harnex-dispatch`
for spawn conventions, watch cadence, and stop timing. This directly
addresses the duplication in the current skill (lines 82–98, 140–175,
178–189 of `skills/harnex-chain/SKILL.md` all restate dispatch
material, including a verbatim duplicate of the poll-cadence table at
lines 178–189 vs. dispatch lines 47–51). **OK.**

### Acceptance criteria testable

Validation checklist (plan lines 93–102) is concrete and can be
verified by grep/read against the final SKILL.md:

- Heading presence: `Orchestrator Role`, `Parallel Variant` — trivially
  checkable.
- Substring checks: "plan-writing", "plan-reviewing", "5", "worktree",
  "harnex-dispatch" references — checkable.
- "Spawn/watch/stop instructions are no longer duplicated in depth" is
  the softest item but operable via a reviewer comparison against
  dispatch. **OK.**

## Risks and gaps

### Risk 1 — Reference target may be underspecified (P2)

The plan requires `harnex-chain` to **reference** `harnex-dispatch`'s
"stop each session the moment its commit lands" rule. Reading the
current `skills/harnex-dispatch/SKILL.md`, I do not find a prominent
"stop early / stop-on-commit" rule. The closest text is:

> "Always verify the agent's work landed before stopping" (line 88)

That is a pre-stop verification rule, not a stop-early rule. Issue #21
§"Context" explicitly claims a precision rewrite of `harnex-dispatch`
already captured this, but the current file does not show it clearly.

Since Plan 21B explicitly scopes out dispatch edits, the referenced
rule may not yet exist in the referenced skill, which would make the
cross-reference dangle — exactly the failure mode Issue #21 §"Explicit
cross-references" warns against.

**Recommendation:** Either
(a) broaden Phase 3 to include adding the stop-on-commit rule to
    `harnex-dispatch` in-line (small, surgical), OR
(b) have Plan 21B inline a one-line stop-on-commit rule inside the
    `Parallel Variant` section instead of only referencing dispatch,
    OR
(c) add an explicit prerequisite: "Verify `harnex-dispatch` contains
    stop-on-commit language before rewriting; if not, file a micro-
    patch first."

Option (b) is the simplest under current scope boundaries.

### Risk 2 — "N" parallelism is underspecified vs. the 5-cap (P3)

Phase 2.3 says "N plan-writes in parallel" and Phase 2.4 says "at most
5 concurrent Codex sessions". The relationship between N and the cap
should be stated once, unambiguously, in the rewrite (e.g. "N ≤ 5
total concurrent Codex sessions across all lanes, not per lane").
Without this, a future orchestrator could run 5 plan-writes + 5
plan-reviews and exceed Azure capacity.

**Recommendation:** Add a sentence to Phase 2 or the validation
checklist making clear the 5-cap is a **total** concurrent cap across
lanes, not per-lane.

### Risk 3 — Serial loop pointer on fix cycles (P3)

The current SKILL.md (lines 118–175) covers plan-fix and code-fix
sub-steps with their own dispatch blocks. The plan calls for trimming
duplicated mechanics but should explicitly say whether the fix
sub-steps survive as chain-specific semantics or also get referenced
to dispatch. Without this, Phase 3 execution risks either over-
trimming (losing the gating semantics between review and fix) or
under-trimming (leaving full command blocks in).

**Recommendation:** In Phase 3, add: "Fix sub-steps (plan-fix,
code-fix) are chain semantics — keep the gating rules but drop the
re-stated `harnex run` command template."

### Nit — Draft outline ordering (P3)

The draft outline (plan lines 79–89) places `Orchestrator Role`
before `Guiding principle and scaling rules`. That matches the intent
("top-priority") but pushes the existing "Guiding Principle" /
"Scale the process to the work" material down. Confirm that is the
desired reading order — orchestrator role first, then scaling guidance
— since a fresh reader may benefit from scale-awareness before role
responsibilities. Minor; either order is defensible.

## Cross-reference sanity

- `harnex-dispatch` exists (`skills/harnex-dispatch/SKILL.md`) and
  owns spawn/watch/stop content — reference target is live.
- `harnex-buddy` is out-of-scope per plan; consistent with Issue #21
  §C.
- The current chain SKILL.md's "Worktree Option" block (lines
  209–214) already defers worktree detail to `harnex-dispatch`;
  the rewrite should keep this pointer.

## Acceptance-mapping verification

Issue #21 acceptance items for Unit B:

| Acceptance item | Covered by plan? |
|---|---|
| `harnex-chain` has explicit Orchestrator Role section | Yes — Phase 1, validation item 1 |
| `harnex-chain` has Parallel Variant with 5-cap + stop-early | Yes — Phase 2.4/2.5, validation items 2–4 |
| No mechanic duplicated across skills | Partially — Phase 3 covers spawn/watch/stop; does not audit every mechanic (acceptable: Unit C owns the cross-reference audit) |

## Verdict

**PASS** with Risk 1 as the only material concern. Risk 1 should be
resolved before implementation starts — pick option (b) inline rule if
you want to hold the scope boundary, otherwise expand scope to patch
dispatch.

Risks 2 and 3 are tightening suggestions; the plan can be implemented
as-written and cleaned up in a follow-up review.
