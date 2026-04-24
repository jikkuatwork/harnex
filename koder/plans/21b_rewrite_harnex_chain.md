# Plan 21B: Rewrite `harnex-chain` Skill for Catalogue Cohesion

Issue: #21 (Unit B)  
Date: 2026-04-24

## ONE THING

Rewrite `skills/harnex-chain/SKILL.md` so role ownership and
parallel-within-chain discipline are explicit, while spawn/watch/stop mechanics
are delegated to `harnex-dispatch`, and add the missing explicit
stop-on-commit rule in `skills/harnex-dispatch/SKILL.md` so the
cross-reference target is concrete.

## Target outcomes

- Add a top-level **Orchestrator Role** section that states:
  - Claude orchestrates only: dispatches, watches, stops, resumes, decides
  - Codex performs all production work: plans, reviews, code, fixes
  - The orchestrator does not implement or review directly
- Keep the serial chain as the default path.
- Add a **Parallel Variant** section that defines:
  - Parallelism is for plan-writing and plan-reviewing passes
  - Cap concurrent Codex sessions at 5 total across all parallel lanes
    (Azure throttling constraint)
  - Stop each finished session immediately after its commit lands, by
    referencing `harnex-dispatch` `## 3. Stop`
    (`skills/harnex-dispatch/SKILL.md#3-stop`) and not duplicating lifecycle prose
  - Implementation remains serial on `master`; parallel implementation requires
    worktrees and explicit user request
- Add an explicit stop-on-commit sentence to `harnex-dispatch` `## 3. Stop`
  so `harnex-chain` references a live rule instead of a missing target.
- Remove duplicate spawn/watch/stop mechanics from `harnex-chain` and reference
  `harnex-dispatch` as the canonical lifecycle source.

## Scope

In scope:
- `skills/harnex-chain/SKILL.md` content and structure rewrite
- `skills/harnex-dispatch/SKILL.md` micro-edit in `## 3. Stop` to add the
  explicit stop-on-commit rule

Out of scope:
- Broader `harnex-dispatch` rewrite beyond the single stop-on-commit addition
- Unit A work (`harnex` collapse/removal)
- Unit C cross-reference audit beyond local checks for this rewrite

## Implementation phases

## Phase 0: Add missing stop-on-commit rule in dispatch (prerequisite)

1. Edit `skills/harnex-dispatch/SKILL.md` under `## 3. Stop`.
2. Add an explicit rule sentence:
   - stop each completed session as soon as its commit lands
   - keep the existing "verify work landed before stopping" guard
3. Treat `skills/harnex-dispatch/SKILL.md#3-stop` as the canonical target for
   `harnex-chain` references.

## Phase 1: Introduce role boundary at top

1. Add `## Orchestrator Role` directly after the skill intro and before the
   workflow detail sections.
2. State responsibilities in imperative terms:
   - Claude: control plane actions and gate decisions
   - Codex: deliverables and code changes
3. Add a clear prohibition line: orchestrator does not take over production
   steps except emergency intervention.

## Phase 2: Add parallel-within-chain guidance

1. Keep the existing serial loop as default.
2. Add `## Parallel Variant` after the serial loop section.
3. Define approved parallel lanes:
   - N plan-writes in parallel (one plan file per Codex session)
   - N plan-reviews in parallel (one review file per Codex session)
4. Add explicit capacity rule: at most 5 concurrent Codex sessions total across
   all lanes (not per lane).
5. Add lifecycle discipline by reference:
   - "Use `harnex-dispatch` Fire & Watch (`#3-stop` for stop timing)"
   - "Stop each completed session as soon as its commit lands"
6. Add implementation constraint:
   - serial implementation on `master` by default
   - parallel implementation only when user explicitly requests worktrees
     (reference dispatch worktree section)

## Phase 3: Trim duplicated lifecycle mechanics

1. Remove or shrink repeated command blocks that restate spawn/watch/stop logic.
2. Remove standalone poll-cadence duplication where dispatch already defines it.
3. Replace duplicate mechanics with concise references to
   `harnex-dispatch` for:
   - spawn conventions (`harnex run ... --tmux`)
   - watch cadence (`harnex pane --lines 20`)
   - stop timing and verification (`harnex stop`)
4. Keep only chain-specific semantics (phase order, gating rules, stop/resume
   decisions, escalation points).
5. Preserve fix-step chain semantics (plan-fix and code-fix gating), but remove
   re-stated generic `harnex run` templates for those steps.

## Draft outline for rewritten `harnex-chain`

1. Title + concise purpose
2. `Orchestrator Role` (new, top-priority)
3. Guiding principle and scaling rules
4. Workflow overview (serial default)
5. Phase sections (issue, optional mapping, extraction, serial loop)
6. `Parallel Variant` (new)
7. Failure/escalation handling
8. Minimal command examples only where chain-specific context matters; all
   lifecycle mechanics referenced to `harnex-dispatch`

## Validation checklist

- [ ] `skills/harnex-chain/SKILL.md` contains `Orchestrator Role` near top
- [ ] `skills/harnex-chain/SKILL.md` contains `Parallel Variant`
- [ ] Parallel section mentions plan-writing, plan-reviewing, and 5-session cap
      as a total cap across lanes (not per lane)
- [ ] `skills/harnex-dispatch/SKILL.md` `## 3. Stop` contains explicit
      stop-on-commit language
- [ ] Parallel section references stop-on-commit discipline via
      `skills/harnex-dispatch/SKILL.md#3-stop`
- [ ] Parallel section states implementation is serial unless explicit
      worktree request
- [ ] Spawn/watch/stop instructions are no longer duplicated in depth; dispatch
      is named as the canonical source
- [ ] Serial loop remains documented as the default
- [ ] Plan-fix/code-fix gating semantics remain, without full duplicated
      dispatch command blocks

## Risks and mitigations

- Risk: over-trimming removes practical operability.
  - Mitigation: keep one short chain-specific example and reference dispatch
    for mechanics.
- Risk: role language stays ambiguous.
  - Mitigation: include explicit "Claude does orchestration; Codex does
    production work" lines in the top section.
- Risk: parallel guidance accidentally implies parallel implementation by
  default.
  - Mitigation: repeat serial-on-master default in both serial loop and
    parallel variant sections.
- Risk: 5-session cap is misread as per-lane instead of global.
  - Mitigation: explicitly state the cap is total across all concurrent lanes.
- Risk: trimming duplicated mechanics also removes fix-loop gating semantics.
  - Mitigation: keep plan-fix/code-fix gate rules while dropping generic
    spawn/watch/stop templates.

## Acceptance mapping (Issue #21 Unit B)

- `harnex-dispatch` `## 3. Stop` includes an explicit stop-on-commit rule that
  `harnex-chain` can reference
- Orchestrator Role section present at top with Claude/Codex boundary
- Parallel Variant section present with:
  - when to parallelize (plan-writing, plan-reviewing)
  - 5-concurrent Codex cap total across all lanes
  - stop-each-session-on-commit rule via
    `skills/harnex-dispatch/SKILL.md#3-stop`
  - worktrees only on explicit request for implementation
- Duplicate lifecycle mechanics removed in favor of `harnex-dispatch` reference
