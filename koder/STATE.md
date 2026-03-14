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

## Confirmed issues from review

1. `harnex send --port` is effectively broken for authenticated requests.
   - The sender can skip registry lookup when `--port` is supplied.
   - The API still requires the bearer token.
   - There is no CLI path to provide that token.
   - Verified by running `harnex send --port 43123 --status`, which returned
     `{"ok":false,"error":"unauthorized"}`.

2. Exit status files and headless logs are keyed only by `id`.
   - This can collide across repos or across repeated runs using the same ID.
   - It is inconsistent with the repo-scoped registry model.

3. `harnex wait` depends on a live registry entry before checking exit status.
   - A fast-exiting detached session can disappear from the registry before
     `wait` starts.
   - In that case, `wait` reports "no session found" even if an exit file exists.

4. Registry filenames normalize IDs more aggressively than the visible ID model.
   - `normalize_id` only trims whitespace.
   - `id_key` lowercases and collapses punctuation.
   - Distinct user-facing IDs can alias onto the same on-disk registry file.

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
