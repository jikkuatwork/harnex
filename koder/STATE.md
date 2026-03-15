# Harnex State

Updated: 2026-03-15

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

- `harnex run` launches a wrapped agent session under a PTY, starts a
  localhost control API, and writes repo-scoped session metadata to the
  local registry.
- `harnex send` resolves a target session, applies relay headers when one
  harnex-managed session talks to another, and sends input through the
  local API.
- `harnex exit` sends the adapter-appropriate exit sequence to a session.
- `harnex status` reads the registry and live status endpoints.
- `harnex wait` blocks until a session exits or reaches a target state
  (`--until prompt`).
- Adapter logic owns CLI-specific launch args, prompt detection, submit
  behavior, and exit sequence.

## Issues

| # | Title | Status | Priority |
|---|-------|--------|----------|
| 01 | Clean exit primitive | **fixed** | P1 |
| 02 | Wait-until-prompt mode | **fixed** | P1 |
| 03 | API & command design audit | **planned** | P1 |
| 04 | Output streaming | open | P2 |
| 05 | Inbox fast-path deadlock | **fixed** | P1 |
| 06 | Full adapter abstraction | open | P2 |

See `koder/issues/` for details.

## Plans

| # | Title | Status |
|---|-------|--------|
| 01 | Monolith refactor | **done** (phases 1-2) |
| 02 | Command & API redesign | **ready** |

See `koder/plans/` for details.

## Next step

**Implement plan 02** (`koder/plans/02_command_redesign.md`).

This is a full CLI/API redesign with 6 phases:
- Phase 0: Generic adapter, binary check, random IDs, --description
- Phase 0b: Adapter contract cleanup
- Phase 1: Renames and removals (exit→stop, legacy env, --label)
- Phase 2: Flag renames on send (--enter→--submit-only, etc.)
- Phase 3: Output consistency (JSON stdout, stderr messages)
- Phase 4: Update tests
- Phase 5: Cleanup (docs, help text)

Read the plan before starting. Each phase is self-contained and
can be committed separately.

## Confirmed bugs from earlier review (all fixed)

1. ~~`harnex send --port` broken for auth~~ → added `--token` flag
2. ~~Exit status files keyed only by `id`~~ → `repo_key--id_key.json`
3. ~~`harnex wait` depends on live registry~~ → falls back to exit file
4. ~~Registry ID normalization collision~~ → `id_key` for matching
