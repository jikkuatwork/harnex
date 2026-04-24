# Review — Issue #21 Unit D Cross-Reference Audit

Commit: 34a09a8 (HEAD)
Plan: koder/plans/21d_cross_reference_audit.md
Reviewer: cx-rev-21d
Date: 2026-04-24

## Verdict: PASS

## Scope verified

Commit 34a09a8 touches exactly the four files in Unit D scope:
- `koder/plans/21d_cross_reference_audit.md` (new plan doc)
- `skills/harnex-dispatch/SKILL.md`
- `skills/harnex-chain/SKILL.md`
- `skills/harnex-buddy/SKILL.md`

No out-of-scope edits.

## Findings matrix — evidence spot-check

All 12 matrix rows are marked Complete with concrete `path:line` evidence.
I verified each citation against the post-commit file contents:

| Row | Canonical cite | Referencer cite(s) | Verified |
|---|---|---|---|
| Fire & Watch lifecycle | dispatch:9 ("spawn, watch, stop") | chain:50, buddy:14 | ✓ |
| Poll cadence 30/60/120 + `pane --lines 20` | dispatch:127 (watch table 132-136, pane 140) | chain:112 ("poll cadence") | ✓ |
| Stop-after-commit | dispatch:169 ("Stop each completed session as soon as its commit lands") | chain:51 ("stop-after-commit timing") | ✓ |
| `--tmux <same-as-id>` naming | dispatch:201 | chain:12-13, buddy:27-28 | ✓ |
| Worktree setup/caveats | dispatch:218 ("Worktree Option") | chain:117 | ✓ |
| Orchestrator role | chain:15 | dispatch:13 | ✓ |
| End-to-end chain phase gates | chain:35 (Workflow Overview) | dispatch:13 | ✓ |
| Parallel + 5 Codex cap | chain:98 (Parallel Variant, 108-109 cap) | buddy:94 | ✓ |
| Buddy activation (overnight / >30min) | buddy:17 | dispatch:258, chain:121 | ✓ |
| Buddy monitor loop | buddy:35 | dispatch:268, chain:122 | ✓ |
| Return channel via `$HARNEX_SPAWNER_PANE` | buddy:63 | dispatch:265, chain:123 | ✓ |
| Buddy cleanup | buddy:84 | dispatch:269 | ✓ |

Every mechanic has exactly one canonical owner and all cross-references name
the target skill explicitly (`harnex-dispatch`, `harnex-chain`, `harnex-buddy`).

## Concrete edit list — applied

### `skills/harnex-chain/SKILL.md`
- Keeps chain-only material: Orchestrator Role (15-23), Workflow Overview
  (37-48), Phase gates (53-96), Parallel Variant with 5-cap (98-117). ✓
- Lifecycle restatements collapsed to one-line pointers: line 8-10 (dispatch
  owns spawn/watch/stop), line 12-13 (naming + worktree → dispatch), line 50-51
  (Fire & Watch + stop-after-commit → dispatch), line 117 (worktree → dispatch).
  ✓
- Buddy escalation reference present at lines 119-124 ("For overnight,
  unattended, or >30-minute steps, use `harnex-buddy`"). ✓

### `skills/harnex-dispatch/SKILL.md`
- Remains canonical for run/watch/stop (95-184), poll cadence table
  (132-136), naming (186-202), worktree (218-247). ✓
- Chain-role trimmed to pointer at lines 12-14 ("For orchestrator role
  boundaries, phase gates, and chain-level parallel policy, see
  `harnex-chain`"). ✓
- Buddy section (256-269) is a short pointer with one spawn example and an
  explicit deferral to `harnex-buddy` for loop/return-channel/cleanup details.
  ✓

### `skills/harnex-buddy/SKILL.md`
- Canonical for activation (17-22), prompt mechanics (35-61), return channel
  (63-77), cleanup (84-90). ✓
- Fire & Watch prose replaced by pointer at line 14 ("Dispatch workers via
  `harnex-dispatch` first"). ✓
- Chain tie-in kept as pointer only at lines 94-95 ("For chain orchestration,
  phase gates, and the 5-concurrent parallel planning cap, see `harnex-chain`").
  ✓

## Duplication scan

Scanned the three files for duplicated non-heading prose blocks. No block
longer than 3 consecutive non-heading lines is repeated across files:

- Buddy spawn example appears in `harnex-dispatch` (263-265) as a 3-line
  minimal pointer snippet and in `harnex-buddy` (30-57) as the canonical,
  substantially expanded form (task file + send). Not a duplicate block —
  different scope and length.
- Return-channel mechanics appear only in `harnex-buddy` (63-77); other skills
  cite by name only.
- Poll table, stop discipline, worktree caveats, naming table, parallel cap,
  orchestrator role: each appears in exactly one file; others cite by name.

No residual overlap > 3 lines or > 1 paragraph detected.

## Acceptance criteria

- [x] Findings matrix filled with per-row evidence (canonical + referencers
      + `path:line`) — plan lines 52-63.
- [x] De-dup edits applied to all three skills.
- [x] No duplicated prose block > 3 consecutive non-heading lines or > 1
      paragraph across the three skills.
- [x] Every mechanic has exactly one canonical owner with named
      cross-references.

## Verdict

**PASS** — Unit D acceptance satisfied. The three-skill catalogue now has
single-owner canonical mechanics with explicit named cross-references, and
the findings matrix is fully evidenced.
