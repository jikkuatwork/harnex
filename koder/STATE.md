# Harnex State

Updated: 2026-10-20 | 10:05 PM | +04

Thin session handoff. History: `CHANGELOG.md`; release evidence:
`koder/releases/`; implementation detail: linked issues/plans.

## Past

- **0.20.0 is installed locally and verified on PATH: harnex is Pi + GPT
  only.** Codex adapters, the JSON-RPC transport, `--fast`/`--legacy-pty` and
  Codex docs/tests are gone; shared behavior is tested through Pi. Record:
  `koder/releases/0.20.0.md`. Same day: 0.19.0 (#85, Pi/GPT workers as native
  Claude tools — `ask`, `run --wait-done`, `final_message`, `--owner-tag`,
  `--until-idle`) and 0.18.0 (#79-#84).
- Owner skills live in `~/Projects/pi/.pi/skills` (`harnex` skill added,
  `koder-pattern` ported to Pi-only; linked for Claude and Pi).
- Suite: 787 runs / 3,916 assertions, no failures.

## Present

- **Owner direction (2026-10-20): exclusively Pi + GPT models.** Do not
  reintroduce Codex; design and verify against Pi.
- **Releases are local only** (no RubyGems, tag or push): suite green →
  version/CHANGELOG → `gem build` → `gem install --local` → installed smoke →
  `koder/releases/<v>.md` → STATE.
- Pi is the only worker adapter that matters; run `pi update` first.
- The `harnex`/`ruby` mise shims need a directory with a Ruby version; a
  scratch dir outside `$HOME` needs its own `.tool-versions` (`ruby 3.3.0`).

## Future (suggested order)

1. **#41 Slice C:** `docs/public_api.md` (docs only; closes #41).
2. **#78:** pane time markers; verify live in a Pi `--tmux` pane.
3. **#17**, then **#16** (macOS portability), then **#59** (conveyor plan +
   first slice; it also owns `--retry-on capacity` from #82).
4. Open questions for the owner: point Pi's `holm-app` skill at Holm's
   canonical `knowledge-base/skills/app` (Claude already uses it); link the
   untracked `feedback` skill for Pi.
