# Harnex State

Updated: 2026-10-20 | 04:48 PM | +04

Thin session handoff. History: `CHANGELOG.md`; release evidence:
`koder/releases/`; implementation detail: linked issues/plans.

## Past

- **0.18.0 is installed locally and verified on PATH.** It closes the
  subagent-orchestration gaps from Holm Queues 159/160: #79 (busy Pi sends
  become follow-ups; lost sends fail loudly), #80 (worktree lanes observed in
  their own repo, `root_commit_sha`), #81 (`after_seq`, `wait --after-seq`,
  `send --wait-done`, per-turn owner results), #82 (`provider_capacity`),
  #83 (`--context-file`/`--context-section`/`--meta-file`), #84
  (`watch --owner --once --cursor`). Record: `koder/releases/0.18.0.md`.
- A Claude Code subagent managed a live Pi lane end to end with these tools
  (blocking foreground calls only); its friction list was fixed pre-release.
- Suite: 939 runs / 4,445 assertions, no failures.

## Present

- **Owner request (2026-10-20):** stress-test Harnex with Claude subagents and
  make Pi/GPT workers feel like native Claude tools. In progress this session.
- **Releases are local only** (no RubyGems, tag or push): suite green →
  version/CHANGELOG → `gem build` → `gem install --local` → installed smoke →
  `koder/releases/<v>.md` → STATE.
- **Codex is deferred.** Pi is the dispatch adapter; run `pi update` first.
- The `harnex`/`ruby` mise shims need a directory with a Ruby version; a
  scratch dir outside `$HOME` needs its own `.tool-versions` (`ruby 3.3.0`).

## Future (suggested order)

1. Finish the Claude-native dispatch work and stress tests (this session).
2. **#41 Slice C:** `docs/public_api.md` (docs only; closes #41).
3. **#78:** pane time markers; verify live in a Pi `--tmux` pane.
4. **#17**, then **#16** (macOS portability), then **#59** (conveyor plan +
   first slice; it also owns `--retry-on capacity` from #82).
