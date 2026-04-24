# Review — 21A Implementation (commit 0ed37c5)

**Verdict: PASS**

Plan: `koder/plans/21a_collapse_harnex_into_dispatch.md`
Commit: `0ed37c5 feat(skills): collapse harnex into dispatch (issue #21 unit A)`

## Acceptance Checklist

- [x] `harnex` no longer installed as a separate catalogue skill.
      `INSTALL_SKILLS` remains `%w[harnex-dispatch harnex-chain harnex-buddy]`;
      `harnex` moved into `DEPRECATED_SKILLS` (`lib/harnex/commands/skills.rb:6-7`).
- [x] `harnex-dispatch/SKILL.md` folds in the formerly unique `harnex` guidance:
      env-var detection table (`HARNEX_ID`, `HARNEX_SESSION_CLI`,
      `HARNEX_SPAWNER_PANE`, etc.), Return-Channel-First rule, Send Hygiene
      (short prompts + file references, explicit reply instruction),
      relay-header awareness, and reply/delegate patterns. `allowed-tools:
      Bash(harnex *)` also added so the skill can invoke harnex without prompts.
- [x] Back-compat alias works. `install harnex --local` maps to
      `harnex-dispatch` via `SKILL_ALIASES` + `canonical_skill_names`; test
      `test_install_harnex_alias_installs_dispatch_without_harnex_dir`
      verifies exit 0, `harnex-dispatch` installed, and no
      `.claude/skills/harnex/` or `.codex/skills/harnex/` artefacts (and also
      asserts only the requested skill is installed, not the full canonical
      set).
- [x] Deprecated names (`harnex`, `dispatch`, `chain-implement`) cleaned on
      both install and uninstall; tests extended
      (`test_install_removes_deprecated_skills`,
      `test_uninstall_also_removes_deprecated_names`).
- [x] Positional-arg rejection test replaced with alias acceptance — matches
      plan step 4.

## Verification

- `ruby -Ilib -Itest test/harnex/commands/skills_test.rb` → **7 runs, 46
  assertions, 0 failures, 0 errors**.
- `grep -rn "skills/harnex/" *.md` on the four cross-ref targets returns no
  stale references:
  - `CLAUDE.md`: updated (line 44 repo-layout line removed, line 83 prose
    now points at `skills/harnex-dispatch/SKILL.md`).
  - `TECHNICAL.md`: updated (§Skill Files rewritten to point at
    `harnex-dispatch`, symlink/install section replaced with the installer
    workflow, deprecated-name cleanup called out).
  - `AGENTS.md`: no `skills/harnex/` references present (already consistent
    from prior commits `a3ca07a` / `5b81d12` — nothing to change here).
  - `CODEX.md`: same — no stale refs. Both files already pointed at
    `harnex-dispatch` before this commit, so omitting them from the diff is
    correct, not a miss.
- Retained stub `skills/harnex/SKILL.md` is a deprecation pointer, not in
  `INSTALL_SKILLS`, so it cannot be installed — consistent with the plan's
  "reduce to short deprecation pointer OR delete" option.

## P1 Findings

None.

## P2 / Nits (optional, not blocking)

1. **Stub file vs. delete** — `skills/harnex/SKILL.md` survives as a
   deprecation pointer. Plan allowed this explicitly. If the goal is to
   prevent future drift, deleting the stub would be cleaner since nothing
   in-repo references the path any more. Not required.
2. **Usage text** — `Harnex::Skills.usage` advertises positional `[SKILL...]`
   only for the combined command line; the `install` line in the subcommand
   list doesn't mention it explicitly. Minor doc polish; functionally fine.
3. **Alias dedup** — `canonical_skill_names` uses `.uniq`, so
   `install harnex dispatch --local` correctly installs one copy of
   `harnex-dispatch`. Good; worth a future test if this pathway becomes
   user-facing.

## Cross-Ref Audit Summary

All four plan-scoped doc files (`CLAUDE.md`, `AGENTS.md`, `CODEX.md`,
`TECHNICAL.md`) are now free of `skills/harnex/SKILL.md` and `skills/harnex/`
references. Remaining hits for that path in the repo are confined to
`koder/plans/` and `koder/reviews/` (historical records) and one line in
`koder/plans/02_command_redesign.md:581` — all out of Unit A scope.

## Conclusion

Implementation matches the plan's acceptance criteria and verification
steps. Tests exercise the back-compat install path. Safe to proceed to
Unit B.
