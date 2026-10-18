# Harnex State

Updated: 2026-10-18 | 03:17 PM | IST

Thin session handoff. History: `CHANGELOG.md`; release evidence:
`koder/releases/`; implementation detail: linked issues/plans.

## Past

- **0.17.0 is installed locally and verified on PATH** from `d53c18c`. It adds
  #77 `harnex watch --owner` (owner-scoped JSON stream for Claude Code
  `Monitor`) and Claude Code owner auto-detection. Earlier the same day:
  0.16.1 (#76 `watch --stall-after`, exit 4) and 0.16.0 (#56 preflight, #57
  outcome classes/budget, #68 final gates, #26, #49). Records:
  `koder/releases/0.16.0.md`, `0.16.1.md`, `0.17.0.md`.
- Suite: 910 runs / 4,280 assertions, no failures. Live-verified on Pi 1.3.0.
- **Every open issue now has an owner decision recorded** (2026-10-18):
  - deferred: #40 #42 #43 (Codex), #58 (Claude is supervisor, not worker);
  - closed: #45 (replaced by #78) and stale #04 #06 #30 #33–#38 #72.

## Present

- **Autonomous mode for the next session.** Each remaining issue has a
  `## Decisions (owner, 2026-10-18) — ready for autonomous implementation`
  section. Implement from it without asking. Stop and ask only if the code
  contradicts a recorded decision.
- **Releases are local only** (no RubyGems, tag or push): suite green →
  version/CHANGELOG → `gem build` → `gem install --local` → installed smoke →
  `koder/releases/<v>.md` → STATE.
- **Codex is deferred** (not used; its key returns 401). Pi is the dispatch
  adapter; run `pi update` before Pi work.
- The `harnex` mise shim needs a directory with a Ruby version: run from the
  project dir and pass `--cwd` for scratch repos.
- `main` is ahead of `origin` and not pushed; push only if the owner asks.

## Future (suggested order)

1. **#41 Slice C:** write `docs/public_api.md` (stable commands, env vars,
   exit codes, JSON schemas). Docs only; closes #41.
2. **#78:** pane time markers (ruler every ~30 lines or 5 min) in Harnex's
   rendered output and transcript; never inside PTY TUIs. Verify live in a Pi
   `--tmux` pane.
3. **#17:** A `send` global fallback, C owner column in `status`, E group
   worktrees in `status --all`, plus worktree/naming docs.
4. **#16:** macOS support: same state path everywhere plus `$XDG_STATE_HOME`;
   portability audit (`/proc/<pid>/stat` in `core.rb` first). Verify
   hermetically; no Mac in this VM.
5. **#59:** write the plan (next monotonic id), then the first slice of
   `harnex conveyor <conveyor.json> [--dry-run]` (schema, dry-run, single-row
   drain, manual continue).
6. Install locally after each logical feature or batch (0.18.x), with a
   release record.
