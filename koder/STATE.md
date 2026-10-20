# Harnex State

Updated: 2026-10-20 | 06:40 PM | +04

Thin session handoff. History: `CHANGELOG.md`; release evidence:
`koder/releases/`; implementation detail: linked issues/plans.

## Past

- **0.19.0 is installed locally and verified on PATH** (#85): Pi/GPT workers
  as native tools for Claude Code — `harnex ask`, `run --wait-done`,
  `final_message` on every turn result, `--owner-tag`, `watch --until-idle` /
  `--match`, per-turn owner history. Two rounds of Claude-subagent stress tests
  drove it. Record: `koder/releases/0.19.0.md`. Earlier today: 0.18.0
  (#79-#84, `koder/releases/0.18.0.md`).
- Owner skills now live in `~/Projects/pi/.pi/skills` (new `harnex` skill
  there, linked into `~/.claude/skills` and `~/.pi/agent/skills`; stale
  Codex-era `dispatch`/`chain-implement` Claude copies removed).
- Suite: 959 runs / 4,532 assertions, no failures.

## Present

- **Owner direction (2026-10-20): exclusively Pi + GPT models.** Codex is to be
  dropped from harnex (adapters, flags, docs, tests); next step.
- **Releases are local only** (no RubyGems, tag or push): suite green →
  version/CHANGELOG → `gem build` → `gem install --local` → installed smoke →
  `koder/releases/<v>.md` → STATE.
- Pi is the only worker adapter that matters; run `pi update` first.
- The `harnex`/`ruby` mise shims need a directory with a Ruby version; a
  scratch dir outside `$HOME` needs its own `.tool-versions` (`ruby 3.3.0`).

## Future (suggested order)

1. **Drop Codex** from harnex (adapters, `--fast`/`--legacy-pty`, docs, tests,
   issues #40 #42 #43), then a local release.
2. **#41 Slice C:** `docs/public_api.md` (docs only; closes #41).
3. **#78:** pane time markers; verify live in a Pi `--tmux` pane.
4. **#17**, then **#16** (macOS portability), then **#59** (conveyor plan +
   first slice; it also owns `--retry-on capacity` from #82).
