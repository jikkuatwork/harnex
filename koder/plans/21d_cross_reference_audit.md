# Plan 21D: Cross-Reference Audit Across Final 3-Skill Catalogue

Issue: #21 (Unit D)  
Date: 2026-04-24  
Depends on: Unit A + Unit B  
Execution order: **Run last**, only after A and B are implemented

## ONE THING

After units A/B land, audit `harnex-dispatch`, `harnex-chain`, and
`harnex-buddy` so each mechanic has exactly one canonical skill home and every
other skill references that mechanic by skill name instead of duplicating prose.

## Preconditions (hard gate before starting D)

- [x] Unit A is implemented (the old `harnex` skill is removed or reduced to a
      pointer, and the active catalogue is the final 3 skills).
- [x] Unit B is implemented (`harnex-chain` includes Orchestrator Role and
      Parallel Variant with 5-concurrent cap).
- [x] Unit A and Unit B are merged to `main`.
- [x] Unit D runs on updated `main` (operator requested `main` execution
      instead of a dedicated audit branch), and contains the final post-A/B
      versions of:
  - `skills/harnex-dispatch/SKILL.md`
  - `skills/harnex-chain/SKILL.md`
  - `skills/harnex-buddy/SKILL.md`

If any gate fails, stop and resume Unit D after A/B merge.

## Scope

In scope:
- Cross-reference/duplication audit across the final 3 skills only
- Canonical mechanic ownership map
- Targeted doc edits to remove duplicated mechanics

Out of scope:
- Runtime code changes
- New skill additions
- Re-opening Unit A/B design decisions

## Findings Matrix (mechanic × canonical owner × reference skills)

Use this as the required ownership contract. During execution, fill the
`Audit status` and `Evidence` columns.

`Evidence` format (required): `path:line` or `path#section-anchor`; list the
canonical entry first, then each referencer entry, separated by `; `.

| Mechanic | Canonical skill where it lives | Skills that reference it by name | Audit status | Evidence |
|---|---|---|---|---|
| Fire & Watch lifecycle (spawn/watch/stop) | `harnex-dispatch` | `harnex-chain`, `harnex-buddy` | Complete | `skills/harnex-dispatch/SKILL.md:9; skills/harnex-chain/SKILL.md:50; skills/harnex-buddy/SKILL.md:14` |
| Poll cadence (30/60/120) + `harnex pane --lines 20` watch practice | `harnex-dispatch` | `harnex-chain` | Complete | `skills/harnex-dispatch/SKILL.md:127; skills/harnex-chain/SKILL.md:112` |
| Stop-after-commit discipline ("stop finished session immediately") | `harnex-dispatch` | `harnex-chain` | Complete | `skills/harnex-dispatch/SKILL.md:169; skills/harnex-chain/SKILL.md:51` |
| Session ID/tmux naming conventions (`--tmux <same-as-id>`) | `harnex-dispatch` | `harnex-chain`, `harnex-buddy` | Complete | `skills/harnex-dispatch/SKILL.md:201; skills/harnex-chain/SKILL.md:12; skills/harnex-buddy/SKILL.md:27` |
| Worktree setup/caveats for parallel isolation | `harnex-dispatch` | `harnex-chain` | Complete | `skills/harnex-dispatch/SKILL.md:218; skills/harnex-chain/SKILL.md:117` |
| Orchestrator role boundary (Claude orchestrates, Codex produces) | `harnex-chain` | `harnex-dispatch` | Complete | `skills/harnex-chain/SKILL.md:15; skills/harnex-dispatch/SKILL.md:13` |
| End-to-end chain flow and phase gates (issue→mapping→extraction→plan loop) | `harnex-chain` | `harnex-dispatch` | Complete | `skills/harnex-chain/SKILL.md:35; skills/harnex-dispatch/SKILL.md:13` |
| Parallel-within-chain rules + 5 concurrent Codex cap | `harnex-chain` | `harnex-buddy` | Complete | `skills/harnex-chain/SKILL.md:98; skills/harnex-buddy/SKILL.md:94` |
| Buddy activation conditions (overnight/unattended/>30m) | `harnex-buddy` | `harnex-dispatch`, `harnex-chain` | Complete | `skills/harnex-buddy/SKILL.md:17; skills/harnex-dispatch/SKILL.md:258; skills/harnex-chain/SKILL.md:121` |
| Buddy monitoring prompt mechanics (poll/stall/nudge loop) | `harnex-buddy` | `harnex-dispatch`, `harnex-chain` | Complete | `skills/harnex-buddy/SKILL.md:35; skills/harnex-dispatch/SKILL.md:268; skills/harnex-chain/SKILL.md:122` |
| Buddy return channel via `$HARNEX_SPAWNER_PANE` and `tmux send-keys` | `harnex-buddy` | `harnex-dispatch`, `harnex-chain` | Complete | `skills/harnex-buddy/SKILL.md:63; skills/harnex-dispatch/SKILL.md:265; skills/harnex-chain/SKILL.md:123` |
| Buddy cleanup (stop buddy after worker completion) | `harnex-buddy` | `harnex-dispatch` | Complete | `skills/harnex-buddy/SKILL.md:84; skills/harnex-dispatch/SKILL.md:269` |

## Concrete edit list to remove duplication

Apply these edits against the post-A/B files.

### `skills/harnex-chain/SKILL.md`

- [x] Keep chain-only material: orchestrator role, phase ordering, gate/decision
      logic, parallel-variant policy, 5-session cap.
- [x] Remove deep lifecycle restatements that belong to dispatch:
  - long spawn/watch/stop command walkthroughs
  - standalone poll-cadence table
  - duplicate stop discipline prose
- [x] Replace removed lifecycle sections with explicit references:
  - "Use Fire & Watch from `harnex-dispatch`."
  - "Use naming/worktree rules from `harnex-dispatch`."
- [x] Add one concise buddy escalation reference for unattended runs:
  - "Use `harnex-buddy` for long-running/unattended monitoring."

### `skills/harnex-dispatch/SKILL.md`

- [x] Remain canonical for run/watch/stop mechanics, poll cadence, naming, and
      worktree operational rules.
- [x] If chain-role text appears here, trim it to a single pointer:
      "See `harnex-chain` for orchestrator boundary."
- [x] Keep buddy mention concise; avoid carrying full buddy prompt mechanics.
      Point to `harnex-buddy` for monitoring loop + return channel details.

### `skills/harnex-buddy/SKILL.md`

- [x] Remain canonical for buddy-specific behavior: activation criteria,
      monitoring cadence, stall detection, nudge protocol, return channel,
      cleanup.
- [x] Remove any repeated Fire & Watch lifecycle prose and replace with:
  - "Dispatch workers via `harnex-dispatch`."
- [x] Keep any chain tie-in as a short pointer only:
  - "For chain orchestration/parallel policy, see `harnex-chain`."

## Audit procedure (execute after A/B)

## Phase 1: Inventory the final catalogue

1. Open the three final SKILL files.
2. Extract headings + key mechanics into a scratch map.
3. Mark each mechanic as either canonical content or duplicate/restatement.

Suggested command aid:

```bash
rg -n "Fire & Watch|poll|30s|60s|120s|worktree|--tmux|Orchestrator Role|Parallel Variant|5-concurrent|buddy|HARNEX_SPAWNER_PANE" \
  skills/harnex-dispatch/SKILL.md skills/harnex-chain/SKILL.md skills/harnex-buddy/SKILL.md
```

## Phase 2: Enforce single-owner mechanics

1. For each row in the findings matrix, confirm only one skill contains
   normative prose + detailed command examples.
2. In non-owner skills, collapse mechanics to one-line references by skill name.
3. Ensure references use explicit names:
   - `harnex-dispatch`
   - `harnex-chain`
   - `harnex-buddy`

## Phase 3: Apply doc edits

1. Edit the three skill docs per the concrete edit list.
2. Keep references short and specific; avoid re-explaining owner mechanics.
3. Re-run a duplication scan and resolve residual overlaps.

## Phase 4: Verify acceptance

- [x] Exactly three harnex skills remain in the installed catalogue:
      dispatch/chain/buddy (verified via `INSTALL_SKILLS` in
      `lib/harnex/commands/skills.rb`)
- [x] Every matrix mechanic has one canonical owner
- [x] Non-owner skills reference canonical mechanics by skill name
- [x] No duplicated prose block larger than 3 consecutive non-heading lines or
      more than 1 paragraph remains across the three skills
- [x] `koder/issues/21_skill_catalogue_cleanup.md` Unit D acceptance is satisfied

## Risks and mitigations

- Risk: over-trimming removes actionable detail.
  - Mitigation: keep full detail in canonical owner; use concise, explicit
    cross-reference links elsewhere.
- Risk: "reference" wording stays vague.
  - Mitigation: require literal skill-name mentions in every cross-skill pointer.
- Risk: A/B changes shift ownership boundaries.
  - Mitigation: run D only after A/B final text is merged; treat this plan's
    matrix as the source of truth for ownership normalization.
