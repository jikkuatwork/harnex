# Plan 21A: Collapse `harnex` into `harnex-dispatch`

Issue: #21 (Unit A)
Date: 2026-04-24

## Goal

Remove the generic `harnex` skill as a first-class installed skill, merge its
unique operating guidance into `harnex-dispatch`, and keep backward
compatibility so `harnex skills install harnex` still works by installing the
canonical `harnex-dispatch` skill.

## Exact File Inventory

### Skill files (Unit A scope)

- `skills/harnex/SKILL.md` (current generic collaboration skill)
- `skills/harnex-dispatch/SKILL.md` (current Fire & Watch lifecycle skill)

### Install-time references in `lib/harnex/commands/skills.rb`

- `SKILLS_ROOT` (`line 5`) points installer at repo `skills/`
- `INSTALL_SKILLS` (`line 6`) defines canonical installed set
- `DEPRECATED_SKILLS` (`line 7`) defines auto-removed legacy names
- `run/install` loop (`lines 37-52`) installs every skill in `INSTALL_SKILLS`
- `run/uninstall` loop (`lines 53-60`) removes `(INSTALL_SKILLS + DEPRECATED_SKILLS)`
- `parse_args` (`lines 73-92`) currently rejects positional skill names
- `remove_deprecated` (`lines 104-108`) is the existing cleanup hook used at
  install time

### Cross-reference cleanup scope (Unit A)

- `CLAUDE.md` (all references to `skills/harnex/SKILL.md` / `skills/harnex/`)
- `AGENTS.md` (all references to `skills/harnex/SKILL.md` / `skills/harnex/`)
- `CODEX.md` (all references to `skills/harnex/SKILL.md` / `skills/harnex/`)
- `TECHNICAL.md` (all references to `skills/harnex/SKILL.md` / `skills/harnex/`)

## Unique `harnex` Content To Fold Into `harnex-dispatch`

Add concise sections to `skills/harnex-dispatch/SKILL.md` for guidance that
exists only in `skills/harnex/SKILL.md` and materially affects dispatch quality:

- Detecting in-session context (`HARNEX_ID`, `HARNEX_SESSION_CLI`,
  `HARNEX_SPAWNER_PANE`)
- Return-channel-first rule before delegation
- Send hygiene:
  - short prompts + file references for long instructions
  - explicit reply instruction in every delegated task
- Relay-header awareness (`[harnex relay ...]`) and response handling
- Practical reply/delegate patterns that complement Fire & Watch

Keep spawn/watch/stop, polling cadence, naming, and stop discipline as the
canonical core owned by `harnex-dispatch`.

## Implementation Steps

1. Consolidate skill content into `skills/harnex-dispatch/SKILL.md`.
2. Retire `skills/harnex/SKILL.md` by reducing it to a short deprecation
   pointer (`Use harnex-dispatch`) or deleting it if no repo docs still depend
   on the path.
3. Update install compatibility in `lib/harnex/commands/skills.rb`:
   - Accept optional positional skill names for `install`.
   - Add alias mapping so deprecated names canonicalize:
     - `harnex` -> `harnex-dispatch`
     - `dispatch` -> `harnex-dispatch`
     - `chain-implement` -> `harnex-chain`
   - Keep zero-arg `install` behavior: install full canonical set from
     `INSTALL_SKILLS`.
   - Extend deprecated cleanup list to include `harnex` so stale installed
     directories are auto-removed before install.
4. Update installer tests in `test/harnex/commands/skills_test.rb`:
   - Replace positional-arg rejection test with alias-acceptance coverage.
   - Add regression: `install harnex` installs `harnex-dispatch` and does not
     install a standalone `harnex` skill directory.
   - Keep existing deprecated auto-remove assertions and extend to include
     `harnex`.
5. Cross-reference cleanup (docs that still point at `skills/harnex/SKILL.md`):
   - `CLAUDE.md`: replace/remove every `skills/harnex/SKILL.md` and
     `skills/harnex/` reference
   - `AGENTS.md`: replace/remove every `skills/harnex/SKILL.md` and
     `skills/harnex/` reference
   - `CODEX.md`: replace/remove every `skills/harnex/SKILL.md` and
     `skills/harnex/` reference
   - `TECHNICAL.md`: replace/remove every `skills/harnex/SKILL.md` and
     `skills/harnex/` reference

## Verification

- `ruby -Ilib -Itest test/harnex/commands/skills_test.rb`
- `harnex skills install --local` installs only canonical three skills
- `harnex skills install harnex --local` succeeds and installs
  `harnex-dispatch` (alias path), with no installed `harnex` skill directory
- `harnex skills uninstall --local` removes canonical + deprecated names

## Acceptance Checklist (Unit A)

- [ ] `harnex` is no longer a separately installed catalogue skill
- [ ] `harnex-dispatch` includes the formerly unique `harnex` guidance sections:
      in-session env-var detection (`HARNEX_ID`, `HARNEX_SESSION_CLI`,
      `HARNEX_SPAWNER_PANE`), return-channel-first rule, relay-header handling,
      and send-hygiene + reply/delegate patterns
- [ ] `harnex skills install harnex --local` exits successfully and installs
      `.claude/skills/harnex-dispatch/` without creating
      `.claude/skills/harnex/`
- [ ] Deprecated installed skill names (`harnex`, `dispatch`, `chain-implement`)
      are cleaned automatically
- [ ] Skills installer tests cover alias compatibility and regression cases
