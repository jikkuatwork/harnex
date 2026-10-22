# Harnex State

Updated: 2026-10-22 | 01:05 PM | IST

Thin session handoff. History: `CHANGELOG.md`; release evidence:
`koder/releases/`; implementation detail: linked issues/plans.

## Past

- **0.21.0 is installed locally; #86 slice 1 is done.** The `gpt` Claude Code
  agent type (`~/Projects/pi/.claude/agents/gpt.md`, linked as
  `~/.claude/agents/gpt.md`) is a Haiku relay over `harnex ask`. The new
  `ask --resume` lets it outlast the 10-minute Bash cap. An 8-lane stress test
  passed (long task, worktree writers, models, fallback). Record:
  `koder/releases/0.21.0.md`.
- 0.20.0 made harnex Pi + GPT only (`koder/releases/0.20.0.md`); 0.19.0 (#85)
  and 0.18.0 (#79-#84) shipped the same week.
- Owner skills live in `~/Projects/pi/.pi/skills` (`harnex` skill added,
  `koder-pattern` ported to Pi-only; linked for Claude and Pi).
- Suite: 788 runs / 3,931 assertions, no failures; Pi 1.4.0 contract test green.

## Present

- **Owner direction (2026-10-20): exclusively Pi + GPT models.** Do not
  reintroduce Codex; design and verify against Pi.
- **Releases are local only** (no RubyGems, tag or push): suite green →
  version/CHANGELOG → `gem build` → `gem install --local` → installed smoke →
  `koder/releases/<v>.md` → STATE.
- Pi is the only worker adapter that matters; run `pi update` first.
- Claude Code loads agent types at session start. Background subagent results
  reach the parent XML-escaped (`&amp;`); the relay's own text is exact.
- The `harnex`/`ruby` mise shims need a directory with a Ruby version; a
  scratch dir outside `$HOME` needs its own `.tool-versions` (`ruby 3.3.0`).

## Future (suggested order)

1. **#86 slice 2:** `harnex mcp` (stdio MCP: `ask`, `delegate`, `send`,
   `status`); then slice 3, the `--worktree` lane shorthand plus capacity
   retry and fallback for `run`.
2. **#41 Slice C:** `docs/public_api.md` (docs only; closes #41).
3. **#78:** pane time markers; verify live in a Pi `--tmux` pane.
4. **#17**, then **#16** (macOS portability), then **#59** (conveyor plan +
   first slice; it also owns `--retry-on capacity` from #82).
5. Open questions for the owner: point Pi's `holm-app` skill at Holm's
   canonical `knowledge-base/skills/app` (Claude already uses it); link the
   untracked `feedback` skill for Pi.
