# Harnex State

Updated: 2026-03-15

## Current snapshot

- `lib/harnex.rb` is a 19-line loader.
- Code is split into separate files:
  - `lib/harnex/core.rb` — constants, env helpers, registry, port allocation
  - `lib/harnex/watcher.rb` + `watcher/{inotify,polling}.rb` — file watching (inotify on Linux, polling fallback on macOS/other)
  - `lib/harnex/adapters.rb` + `adapters/{base,generic,codex,claude}.rb`
  - `lib/harnex/runtime/{session_state,message,inbox,session,file_change_hook,api_server}.rb`
  - `lib/harnex/commands/{run,send,wait,stop,status,logs}.rb`
  - `lib/harnex/cli.rb`
- Test suite: `test/` with 146 minitest tests, all passing.
- CLI entrypoint is `bin/harnex` (unchanged).
- Command/API redesign is implemented: generic adapter fallback, binary
  validation, random session IDs, `--description`, `stop`, `status --json`,
  and the renamed `send` flags are all live.
- Issue docs `01`, `02`, `03`, and `05` now match the implemented command and
  status surface.
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
- Layer A (multi-agent reliability) is implemented:
  - `harnex stop` now uses a 75ms delay between exit text and submit in
    Claude/Codex adapters, matching the `build_send_payload` pattern.
  - `harnex send` default timeout raised from 30s to 120s for fresh sessions.
  - Claude adapter detects vim normal mode (`NORMAL`/`--NORMAL--`) as a
    sendable state (`vim-normal`, `input_ready: true`).
  - Inbox has TTL auto-expiry (default 120s), `pending_messages`, `drop`,
    `clear` methods, and API endpoints (`GET /inbox`, `DELETE /inbox`,
    `DELETE /inbox/:id`). Configurable via `--inbox-ttl` or `HARNEX_INBOX_TTL`.

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
- `harnex wait` blocks until a session exits or reaches a target state
  (`--until prompt`).
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
| 04 | Output streaming | open | P2 |
| 05 | Inbox fast-path deadlock | **fixed** | P1 |
| 06 | Full adapter abstraction | open | P2 |
| 07 | `stop` types exit but doesn't submit | **fixed** | P1 |
| 08 | Send to fresh Codex times out | **fixed** | P2 |
| 09 | Claude vim mode not detected | **fixed** | P2 |
| 10 | Inbox management (list/drop/TTL) | **fixed** | P2 |
| 11 | Tmux pane capture | open | P3 |
| 12 | State detection failures cause send/receive problems | open | P1 |

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

Plans 04-07 are **layer A** (multi-agent reliability).

See `koder/plans/` for details.

## Next step

**Implement phase 3 of the output streaming plan (03):** add the read-only,
authenticated output API on top of the transcript file so local tools can tail
session output by byte offset.

Alternatively, fix issue #12 (state detection failures) which is P1 and
blocks reliable agent-to-agent messaging, or tackle issue #11 (tmux pane
capture) which is a quick diagnostic tool for tmux-backed sessions.

## Confirmed bugs from earlier review (all fixed)

1. ~~`harnex send --port` broken for auth~~ -> added `--token` flag
2. ~~Exit status files keyed only by `id`~~ -> `repo_key--id_key.json`
3. ~~`harnex wait` depends on live registry~~ -> falls back to exit file
4. ~~Registry ID normalization collision~~ -> `id_key` for matching
