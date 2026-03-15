# Harnex State

Updated: 2026-03-14

## Current snapshot

- `lib/harnex.rb` is a 20-line loader.
- Code is split into separate files:
  - `lib/harnex/core.rb` — constants, env helpers, registry, port allocation
  - `lib/harnex/linux_inotify.rb` — inotify via Fiddle
  - `lib/harnex/adapters.rb` + `adapters/{base,codex,claude}.rb`
  - `lib/harnex/runtime/{session_state,message,inbox,session,file_change_hook,api_server}.rb`
  - `lib/harnex/commands/{run,send,wait,exit,status}.rb`
  - `lib/harnex/cli.rb`
- Test suite: `test/` with 84 minitest tests, all passing.
- CLI entrypoint is `bin/harnex` (unchanged).

## What harnex does

Harnex is a local PTY harness for interactive terminal agents.

- `harnex run` launches a wrapped Codex or Claude session under a PTY, starts a
  localhost control API, and writes repo-scoped session metadata to the local
  registry.
- `harnex send` resolves a target session, applies relay headers when one
  harnex-managed session talks to another, and sends input through the local API.
- `harnex exit` sends the adapter-appropriate exit sequence to a session.
- `harnex status` reads the registry and live status endpoints.
- `harnex wait` blocks on a detached session and reports exit status.
- Adapter logic owns CLI-specific launch args, prompt detection, submit
  behavior, and exit sequence.

## Features currently implemented

- ID-based session addressing
- adapter-driven prompt detection
- inbox queue with delayed delivery when the agent is busy
- detached headless sessions via `--detach`
- tmux-backed detached sessions via `--tmux`
- `wait` command for detached workers
- `exit` command for clean session termination
- relay headers for cross-session sends
- file-change hooks using inotify on Linux

## Issues

| # | Title | Status | Priority |
|---|-------|--------|----------|
| 01 | Clean exit primitive | **fixed** | P1 |
| 02 | Wait-until-prompt mode | **fixed** | P1 |
| 03 | API & command design audit | **planned** | P1 |
| 04 | Output streaming | open | P2 |
| 05 | Inbox fast-path deadlock | **fixed** | P1 |

See `koder/issues/` for details.

## Confirmed bugs from earlier review (all fixed)

1. ~~`harnex send --port` broken for authenticated requests~~ → added `--token` flag
2. ~~Exit status files keyed only by `id`~~ → now uses `repo_key--id_key.json`
3. ~~`harnex wait` depends on live registry entry~~ → falls back to exit status file
4. ~~Registry ID normalization collision~~ → `active_sessions` now uses `id_key` for matching

## What was done this session

- **Refactor Phase 1**: Added minitest harness with 75 tests across 7 files.
- **Refactor Phase 2**: Extracted `lib/harnex.rb` (~1900 lines) into 13
  separate files. It is now a 20-line loader.
- **Fixed issue #05**: Inbox fast-path deadlock — restructured `enqueue` to
  release mutex before calling `deliver_now`.
- **Fixed 4 confirmed bugs** with tests:
  1. Added `--token` flag to `harnex send` for `--port` mode auth
  2. Exit files now keyed by `repo_key--id_key` (no cross-repo collision)
  3. `harnex wait` falls back to exit status file when registry is gone
  4. `active_sessions` uses `id_key` for matching (consistent with disk keys)
- **Fixed issue #01**: Clean exit primitive — added `harnex exit --id <ID>`,
  `POST /exit` API endpoint, and `exit_sequence` adapter method.

## Refactor plan

See `koder/plans/01_refactor.md`.

Phases 1–2 are complete. All confirmed bugs are fixed.
Phase 3 (idiomatic cleanup: namespacing under `Harnex::Commands`, aliases) is
optional.

## Recommended next step after restart

1. Work on issue #02 (wait-until-prompt mode).
2. Work on issue #03 (API & command design audit).
3. Optionally do Phase 3 cleanup.
