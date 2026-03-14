# Harnex State

Updated: 2026-03-14

## Current snapshot

- Main implementation is still concentrated in `lib/harnex.rb` at about 1895
  lines.
- Adapters are already split into:
  - `lib/harnex/adapters/base.rb`
  - `lib/harnex/adapters/codex.rb`
  - `lib/harnex/adapters/claude.rb`
- CLI entrypoint is `bin/harnex`.
- Refactor plan has been created at `koder/plans/01_refactor.md`.
- No implementation refactor has started yet.
- No automated tests are present yet. A quick search found no `test/` or
  `spec/` tree in the repo.

## What harnex does

Harnex is a local PTY harness for interactive terminal agents.

- `harnex run` launches a wrapped Codex or Claude session under a PTY, starts a
  localhost control API, and writes repo-scoped session metadata to the local
  registry.
- `harnex send` resolves a target session, applies relay headers when one
  harnex-managed session talks to another, and sends input through the local API.
- `harnex status` reads the registry and live status endpoints.
- `harnex wait` blocks on a detached session and reports exit status.
- Adapter logic owns CLI-specific launch args, prompt detection, and submit
  behavior.

## Features currently implemented

- ID-based session addressing
- adapter-driven prompt detection
- inbox queue with delayed delivery when the agent is busy
- detached headless sessions via `--detach`
- tmux-backed detached sessions via `--tmux`
- `wait` command for detached workers
- relay headers for cross-session sends
- file-change hooks using inotify on Linux

## Issues

| # | Title | Status | Priority |
|---|-------|--------|----------|
| 01 | Clean exit primitive | open | P1 |
| 02 | Wait-until-prompt mode | open | P1 |
| 03 | API & command design audit | open | P1 |
| 04 | Output streaming | open | P2 |

See `koder/issues/` for details.

Issue 03 subsumes the four confirmed bugs below (3d covers exit file collision,
3e covers registry fallback, `--port` auth is covered by the `--status`/mode
cleanup, normalization collision is part of the broader ID resolution fix).

## Confirmed bugs from earlier review

1. `harnex send --port` broken for authenticated requests (no CLI token path)
2. Exit status files keyed only by `id` (collides across repos) → Issue 03d
3. `harnex wait` depends on live registry entry (race with fast-exit sessions)
4. Registry ID normalization collision (`normalize_id` vs `id_key`)

## Review summary

What looks good:

- The project scope is disciplined. It is a harness and local control plane, not
  a full orchestration system.
- The adapter seam is the right abstraction boundary.
- The workflow primitives are useful and concrete:
  - repo-scoped discovery
  - relay headers
  - queued sends
  - detached and tmux sessions
  - waitable worker sessions

Main concern:

- The project has outgrown the single-file implementation. The current logic
  mixes config, registry, CLI parsing, PTY/session runtime, HTTP API, queueing,
  and waiting in one file.

## What was done this turn

- Read and reviewed:
  - `README.md`
  - `bin/harnex`
  - `lib/harnex.rb`
  - `lib/harnex/adapters/*.rb`
  - `koder/STATE.md`
- Confirmed current architecture and control flow.
- Verified syntax with:
  - `ruby -c bin/harnex`
  - `ruby -c lib/harnex.rb`
  - `ruby -c lib/harnex/adapters/base.rb`
  - `ruby -c lib/harnex/adapters/codex.rb`
  - `ruby -c lib/harnex/adapters/claude.rb`
- Created the refactor plan file:
  - `koder/plans/01_refactor.md`
- No production code was changed in this turn.

## Refactor plan

See `koder/plans/01_refactor.md`.

The plan is to split the code into:

- core/config helpers
- Linux inotify wrapper
- runtime/session classes
- command classes
- CLI loader
- a new `test/` tree using `minitest`

## Recommended next step after restart

1. Open `koder/plans/01_refactor.md`.
2. Add a small `minitest` harness first.
3. Extract `core.rb` and `linux_inotify.rb`.
4. Extract runtime classes next.
5. Extract command classes and reduce `lib/harnex.rb` to a loader.
6. Fix the four confirmed issues above while adding tests around them.

## Current worktree changes

- `koder/plans/01_refactor.md`
- `koder/STATE.md`
