# Review: Plan 21A — Collapse `harnex` into `harnex-dispatch`

Date: 2026-04-24
Reviewer: cl-rev-plan-21a
Verdict: **NEEDS MINOR FIXES** — sound approach and accurate refs, but
cross-reference list is incomplete and a couple of acceptance items should be
made more testable.

## Summary

The plan correctly identifies the files it touches, sequences the edits in a
workable order, and preserves the `harnex skills install harnex` invocation via
aliasing. The main gaps are in the cross-reference cleanup (step 5) — it misses
several in-repo files that still point at `skills/harnex/SKILL.md` — and two
acceptance criteria that are stated qualitatively where they could be made
objective.

## Accuracy of file / function refs

Verified against `lib/harnex/commands/skills.rb`:

- `SKILLS_ROOT` at line 5 ✓
- `INSTALL_SKILLS = %w[harnex-dispatch harnex-chain harnex-buddy]` at line 6 ✓
- `DEPRECATED_SKILLS = %w[dispatch chain-implement]` at line 7 ✓
- `run`/install block at lines 37–52 ✓ (install loop proper is 43–51; range in
  plan includes the `when "install"` guard, which is fine)
- `run`/uninstall block at lines 53–60 ✓
- `parse_args` at lines 73–92, rejects positional args at lines 85–88 ✓
- `remove_deprecated` at lines 104–108 ✓

Skill content references:
- `skills/harnex/SKILL.md` exists and contains the unique sections the plan
  lists (in-session detection, return-channel-first, relay-header awareness,
  send hygiene, reply/delegate patterns). ✓
- `skills/harnex-dispatch/SKILL.md` currently has spawn/watch/stop, polling
  cadence, naming table, worktree, buddy pointer, what-not-to-do. The plan's
  division of ownership (fold collaboration guidance in; keep Fire & Watch core
  canonical) is accurate.

## Sequencing

Order is reasonable: content consolidation → skill retirement → installer
alias → tests → cross-ref docs. One small risk: if step 2 deletes
`skills/harnex/SKILL.md` before step 5 scrubs the docs pointing at it, the
repo briefly contains broken doc links. Either run step 5 before step 2, or
adopt the "short deprecation pointer" variant in step 2 until step 5 lands.
Worth calling out explicitly in the plan.

## Back-compat for `harnex skills install harnex`

The alias approach (`harnex` → `harnex-dispatch`, `dispatch` →
`harnex-dispatch`, `chain-implement` → `harnex-chain`) is correct and
sufficient to keep the user-facing invocation working. Two details to tighten:

1. After aliasing, the installer must **not** also create a
   `~/.claude/skills/harnex/` directory (the plan says this but it is worth an
   explicit assertion: the skill source resolution must use the canonical name,
   not the supplied alias).
2. `DEPRECATED_SKILLS` needs `harnex` added — plan step 3 covers this, but
   step 4's test list should assert the removal of a pre-existing
   `~/.claude/skills/harnex/` directory on install, mirroring the existing
   `dispatch` / `chain-implement` coverage (`skills_test.rb:60–79`,
   `:123–137`). Plan implies this in step 4 bullet 3 but could be explicit.

## Acceptance criteria — testability

| # | Criterion | Testable? | Notes |
|---|-----------|-----------|-------|
| 1 | `harnex` no longer a separately installed skill | Yes | Covered by installer test + `INSTALL_SKILLS` inspection |
| 2 | Unique `harnex` guidance lives in `harnex-dispatch` | **Soft** | Reword as a checklist (return-channel section present, relay-header section present, in-session env-var table present, send-hygiene rules present) so review can confirm objectively |
| 3 | `harnex skills install harnex` still works via alias | Yes | Add a test: `Harnex::Skills.new(["install","harnex","--local"]).run` returns 0 and produces `.claude/skills/harnex-dispatch/` but no `.claude/skills/harnex/` |
| 4 | Deprecated names auto-cleaned | Yes | Extend existing `test_install_removes_deprecated_skills` to include `harnex` |
| 5 | Installer tests cover alias + regressions | Yes | Straightforward |

## Gaps in step 5 (cross-reference cleanup)

Step 5 names `AGENTS.md` and "manual-install examples", but a grep of the repo
turns up several more places that reference `skills/harnex/SKILL.md` and need
updating or removal:

- `CLAUDE.md:44` — repo-layout line: `skills/harnex/SKILL.md  Core harnex skill`
- `CLAUDE.md:84` — prose: `See \`skills/harnex/SKILL.md\` for full usage patterns`
- `AGENTS.md:44` — same layout line (mirror of CLAUDE.md)
- `AGENTS.md:84` — same prose
- `CODEX.md:44` — same layout line
- `CODEX.md:84` — same prose
- `TECHNICAL.md:510` — reference to `skills/harnex/SKILL.md`
- `TECHNICAL.md:575` — "symlink points to the `skills/harnex/` directory"
- `koder/plans/02_command_redesign.md:581` — historical plan; fine to leave
  as-is (it is an archived plan), but worth a note in the commit message.

The plan should list these explicitly so the implementer doesn't miss the
`CLAUDE.md` / `CODEX.md` / `TECHNICAL.md` occurrences. `README.md` does not
reference `skills/harnex/` directly — good — but line 21 advertises skills as
"harnex-dispatch, harnex-chain, harnex-buddy" which already matches the new
canonical set, so no change needed there.

## Smaller notes

- Step 2 options ("short deprecation pointer" vs "delete") should be decided
  up-front rather than left open. Given the alias approach already handles the
  CLI invocation, deleting the file and updating the doc refs is cleaner and
  avoids a stub that could diverge. Recommend: delete `skills/harnex/SKILL.md`
  and do the cross-ref cleanup in the same commit.
- Verification bullet `harnex skills install --local installs only canonical
  three skills` is good; add a mirror bullet `harnex skills install harnex
  --local produces .claude/skills/harnex-dispatch/ and no .claude/skills/harnex/`.
- The plan does not mention updating `koder/STATE.md` or issue #21 itself;
  that is presumably out of scope for Unit A, but worth a one-line "scope note"
  so it isn't flagged during review.

## Conclusion

Plan is structurally correct and touches the right files. Tighten:

1. Expand step 5 to the full file list above (CLAUDE.md, AGENTS.md, CODEX.md,
   TECHNICAL.md).
2. Resolve step 2's delete-vs-stub ambiguity.
3. Promote acceptance item #2 to an objective checklist.
4. Add the explicit alias-regression test case to step 4.
5. Note the sequencing dependency between step 2 and step 5.

With those edits, the plan is ready to implement.
