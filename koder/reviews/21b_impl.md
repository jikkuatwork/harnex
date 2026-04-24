# Review: Issue #21 Unit B — Rewrite `harnex-chain`

Commit: a95771c
Plan: koder/plans/21b_rewrite_harnex_chain.md
Issue: koder/issues/21_skill_catalogue_cleanup.md
Reviewer: cx-rev-21b
Date: 2026-04-24

## Verdict

**PASS**

## Checks

### Orchestrator Role at top (Claude orchestrates, Codex produces)
PASS — `skills/harnex-chain/SKILL.md:12-19`. Section sits directly
after the intro and before workflow detail. States:
- Claude: dispatches, watches, decides stop/resume/escalate, enforces gates.
- Codex: plans, plan reviews, implementation, code reviews, fixes.
- Explicit prohibition on orchestrator doing production work except emergency
  intervention.

### Parallel Variant covers plan-writing and plan-reviewing
PASS — `skills/harnex-chain/SKILL.md:96-104`. Approved lanes are
explicitly "parallel plan-writing" and "parallel plan-review" only.

### 5-concurrent Codex cap, global across lanes
PASS — `skills/harnex-chain/SKILL.md:105-107`. "at most 5 concurrent
Codex sessions total across all active lanes (global cap, not per lane)".
Language disambiguates total vs per-lane as required by plan risk mitigation.

### Stop-on-commit referenced from harnex-dispatch #3-stop
PASS — `skills/harnex-chain/SKILL.md:109-112`. Lifecycle rule cites
`skills/harnex-dispatch/SKILL.md#3-stop` and repeats the "stop each completed
session as soon as its commit lands" sentence.

### Stop-on-commit rule actually exists in harnex-dispatch
PASS — `skills/harnex-dispatch/SKILL.md:161-165`. `## 3. Stop` now
contains the explicit sentence "Stop each completed session as soon as its
commit lands." The existing "verify the agent's work landed before stopping"
guard (`:171-180`) is preserved. Anchor `#3-stop` matches the GitHub-style
slug the chain file references.

### Duplicated spawn/watch/stop mechanics trimmed
PASS — `skills/harnex-chain/SKILL.md:47-49, 110, 140`. The file
delegates lifecycle mechanics to `harnex-dispatch` and contains no duplicated
`harnex run` / `harnex pane` / `harnex stop` command blocks. Only chain
semantics (phase order, gating, naming IDs, escalation) remain. Naming section
ends with "For run/watch/stop command patterns, use `harnex-dispatch`
directly."

### Implementation remains serial-on-main default
PASS — `skills/harnex-chain/SKILL.md:32-45` (Workflow Overview labeled
"Serial Default", diagram notes "serial on main"), `:80-94` (Phase 4 Serial
Plan Loop is the default path), and `:98-99, 114-117` (Parallel Variant
repeats: "Keep implementation serial on `main`"; "Parallel implementation is
allowed only with explicit user request and worktree isolation"). The
serial-default invariant is stated in all three required places per the plan's
risk mitigation.

### Fix-step gating preserved
PASS — `skills/harnex-chain/SKILL.md:91-94`. Plan-fix and code-fix
gating rules retained: no impl with unresolved P1 plan-review findings; no
advance with unresolved P1 code-review findings; fix loops continue until
review gates pass. No duplicated dispatch templates.

## Validation checklist (from plan)

- [x] `Orchestrator Role` near top
- [x] `Parallel Variant` present
- [x] Plan-writing, plan-reviewing, 5-session total cap
- [x] `harnex-dispatch` `## 3. Stop` contains explicit stop-on-commit language
- [x] Parallel section references `skills/harnex-dispatch/SKILL.md#3-stop`
- [x] Implementation serial unless explicit worktree request
- [x] Spawn/watch/stop not duplicated; dispatch named as canonical source
- [x] Serial loop remains the default
- [x] Plan-fix/code-fix gating preserved without duplicated dispatch blocks

## Notes / optional nits (non-blocking)

- Minor: `Workflow Overview` diagram says "serial on main" while prose
  elsewhere uses "main" consistently — consistent. No change needed.
- Minor: The stop-on-commit sentence in dispatch `## 3. Stop` lands before
  the "verify work landed before stopping" block. Order is fine because the
  verification block is framed as a reinforcement ("Always verify..."), but a
  future editorial pass could merge them into one bullet list. Out of scope
  for this unit.

No P1 or P2 issues found. Ship.
