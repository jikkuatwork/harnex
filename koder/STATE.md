# Harnex State

Updated: 2026-03-17

## Current snapshot

- `lib/harnex.rb` is a 21-line loader.
- Code is split into separate files:
  - `lib/harnex/core.rb` — constants, env helpers, registry, port allocation
  - `lib/harnex/watcher.rb` + `watcher/{inotify,polling}.rb` — file watching (inotify on Linux, polling fallback on macOS/other)
  - `lib/harnex/adapters.rb` + `adapters/{base,generic,codex,claude}.rb`
  - `lib/harnex/runtime/{session_state,message,inbox,session,file_change_hook,api_server}.rb`
  - `lib/harnex/commands/{run,send,wait,stop,status,logs,pane,recipes,guide,skills}.rb`
  - `lib/harnex/cli.rb`
- Test suite: `test/` with 171 minitest tests, all passing.
- CLI entrypoint is `bin/harnex` (unchanged).
- Command/API redesign is implemented: generic adapter fallback, binary
  validation, random session IDs, `--description`, `stop`, `status --json`,
  and the renamed `send` flags are all live.
- Issue docs `01`, `02`, `03`, and `05` now match the implemented command and
  status surface.
- `harnex send --wait-for-idle` makes send+wait atomic: sends the message,
  polls until the agent transitions prompt→busy→prompt, and returns a single
  JSON result. Eliminates the `sleep 5` workaround in orchestration workflows.
  Uses a 30s fence timeout for instant-response agents and reuses `--timeout`
  for the full lifecycle.
- `harnex run` rejects duplicate session IDs — fails fast with a clear error
  if the ID is already active on the same repo.
- New CLI commands for documentation and onboarding:
  - `harnex guide` — prints GUIDE.md (getting started walkthrough)
  - `harnex recipes` — lists and shows workflow recipes (fire-and-watch,
    chain-implement)
  - `harnex skills install` — copies the harnex skill into a repo's
    `.claude/skills/` and symlinks `.codex/skills/` to it
- README rewritten for non-users (quick "is this for me?" format). Usage
  details moved to GUIDE.md, command reference stays in TECHNICAL.md.
- `recipes/` directory with tested workflow patterns:
  - `01_fire_and_watch` — atomic unit: spawn, send, pane poll, capture
  - `02_chain_implement` — batch implement→review→fix loop
- Output streaming phases 1-2 are in place: every session writes a repo-keyed
  transcript file at `~/.local/state/harnex/output/<repo>--<id>.log`, exposed
  as `output_log_path` in status payloads and detached `run` responses, and
  `harnex logs` can snapshot the last N lines or `--follow` appended output
  without depending on the session HTTP API.
- Exit status records now preserve signal metadata as `signal` alongside the
  synthesized numeric `exit_code` for signaled sessions, with regression tests
  covering zero-exit and signaled-exit persistence.
- File watching is now cross-platform: inotify on Linux, stat-polling fallback
  on macOS and other platforms. Zero external dependencies maintained.
- OSC escape sequence stripping fixed: greedy regex was consuming entire
  screen buffers when multiple OSC sequences were present, breaking state
  detection for both Codex and Claude adapters.
- Layer A (multi-agent reliability) is implemented:
  - `harnex stop` now uses a 75ms delay between exit text and submit in
    Claude/Codex adapters, matching the `build_send_payload` pattern.
  - `harnex send` default timeout raised from 30s to 120s for fresh sessions.
  - Claude adapter detects vim normal mode (`NORMAL`/`--NORMAL--`) as a
    sendable state (`vim-normal`, `input_ready: true`).
  - Inbox has TTL auto-expiry (default 120s), `pending_messages`, `drop`,
    `clear` methods, and API endpoints (`GET /inbox`, `DELETE /inbox`,
    `DELETE /inbox/:id`). Configurable via `--inbox-ttl` or `HARNEX_INBOX_TTL`.
- Issue #11 is now implemented: `harnex pane --id <session>` captures a clean
  tmux screen snapshot for live sessions, supports `--lines`/`--json`/`--follow`,
  and fails clearly when `tmux` is unavailable or the session is not tmux-backed.
  `--follow` refreshes the screen at a configurable interval until the session
  exits, effectively solving the supervisor monitoring use case and making the
  output streaming HTTP API (issue #04 phase 3) low priority.

## What harnex does

Harnex is a local PTY harness for interactive terminal agents.

- `harnex run` launches a wrapped agent session under a PTY, starts a
  localhost control API, and writes repo-scoped session metadata to the
  local registry.
- `harnex send` resolves a target session, applies relay headers when one
  harnex-managed session talks to another, and sends input through the
  local API.
- `harnex stop` sends the adapter-appropriate stop sequence to a session.
- `harnex status` reads the registry and live status endpoints, with table
  or JSON output.
- `harnex logs` reads the persisted transcript for a live or exited session,
  with last-N snapshot output and polling `--follow` mode.
- `harnex pane` reads the current tmux pane for a live session and prints a
  clean screen snapshot, optionally limited to the last N lines or wrapped in
  JSON metadata. `--follow` refreshes the snapshot at a configurable interval
  until the session exits.
- `harnex wait` blocks until a session exits or reaches a target state
  (`--until prompt`).
- `harnex guide` prints the getting started guide.
- `harnex recipes` lists and shows workflow recipes.
- `harnex skills install` copies the skill into a repo for Claude/Codex.
- Adapter logic owns CLI-specific launch args, prompt detection, submit
  behavior, stop sequence, and send-readiness waiting.
- Session output is mirrored to the terminal, stored in a 64KB ring buffer for
  prompt detection, and appended to a repo-keyed transcript file for later
  access.

## Issues

| # | Title | Status | Priority |
|---|-------|--------|----------|
| 01 | Clean stop primitive | **fixed** | P1 |
| 02 | Wait-until-prompt mode | **fixed** | P1 |
| 03 | API & command design audit | **fixed** | P1 |
| 04 | Output streaming | open | P3 |
| 05 | Inbox fast-path deadlock | **fixed** | P1 |
| 06 | Full adapter abstraction | open | P2 |
| 07 | `stop` types exit but doesn't submit | **fixed** | P1 |
| 08 | Send to fresh Codex times out | **fixed** | P2 |
| 09 | Claude vim mode not detected | **fixed** | P2 |
| 10 | Inbox management (list/drop/TTL) | **fixed** | P2 |
| 11 | Tmux pane capture | **fixed** | P3 |
| 12 | State detection failures cause send/receive problems | **fixed** | P1 |
| 13 | Atomic `send --wait-for-idle` | **fixed** | P1 |

See `koder/issues/` for details.

## Plans

| # | Title | Status |
|---|-------|--------|
| 01 | Monolith refactor | **done** (phases 1-2) |
| 02 | Command & API redesign | **done** |
| 03 | Output streaming | **in progress** (phases 1-2 done) |
| 04 | Stop submit fix (#07) | **done** |
| 05 | Send startup timeout (#08) | **done** |
| 06 | Claude vim mode (#09) | **done** |
| 07 | Inbox management (#10) | **done** |
| 08 | Pane capture (#11) | **done** |
| 09 | Atomic send --wait-for-idle (#13) | **done** |

Plans 04-08 are **layer A** (multi-agent reliability).
Plan 09 is **layer B** (atomic orchestration primitives).

See `koder/plans/` for details.

## Next step

Packaged as gem v0.1.4 (not yet published to rubygems). Install locally
with `gem build harnex.gemspec && gem install ./harnex-0.1.4.gem`.

Dogfooding confirmed: used harnex to spawn Codex and delegate issue #13
implementation. Hit the exact send→wait race condition during the process,
validating the fix.

Output streaming phase 3 (HTTP API) is deferred — `harnex pane --follow`
covers the primary supervisor monitoring use case. Issue #06 (full adapter
abstraction) is intentionally deferred until a third adapter hits the wall
with the current contract.

Potential next work:
- Build a third adapter (aider, cursor, etc.) to naturally drive #06
- Tackle retention/rotation for transcript files if they grow large
- Public gem release

## Confirmed bugs from earlier review (all fixed)

1. ~~`harnex send --port` broken for auth~~ -> added `--token` flag
2. ~~Exit status files keyed only by `id`~~ -> `repo_key--id_key.json`
3. ~~`harnex wait` depends on live registry~~ -> falls back to exit file
4. ~~Registry ID normalization collision~~ -> `id_key` for matching
