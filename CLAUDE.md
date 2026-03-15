# Harnex — Agent Orientation

**Read `koder/STATE.md` first.** It tracks the current project state,
open issues, active plans, and the recommended next step. It is the
handoff document between agent sessions.

## Project tracking

- `koder/STATE.md` — current state, issues table, next step
- `koder/issues/` — individual issue files (features, bugs, ideas)
- `koder/plans/` — implementation plans with phased instructions

Always check STATE.md at the start of a session to orient yourself.
If you complete work, update STATE.md before ending.

## What is harnex?

A PTY harness that wraps terminal AI agents and adds a local control
plane for discovery, messaging, and coordination. It does not change
the wrapped agent's UI — it runs alongside it.

## Repo layout

```
bin/harnex                       CLI entry point
lib/harnex.rb                    Loader (requires all modules)
lib/harnex/core.rb               Constants, env, registry, port allocation
lib/harnex/cli.rb                Top-level command dispatch
lib/harnex/commands/             Command implementations (run, send, wait, stop, status, logs, pane)
lib/harnex/runtime/              Session, state machine, inbox, API server
lib/harnex/adapters/             Adapter base + generic/codex/claude adapters
lib/harnex/watcher.rb            File watcher (auto-selects backend)
lib/harnex/watcher/inotify.rb    Linux inotify via Fiddle
lib/harnex/watcher/polling.rb    Cross-platform stat-based fallback
test/                            Minitest suite (163 tests)
koder/STATE.md                   Project state (read this first)
koder/issues/                    Issue tracker
koder/plans/                     Implementation plans
skills/harnex/SKILL.md           Skill file for Claude/Codex integration
```

## Key classes

- **`Harnex::CLI`** — command dispatch
- **`Harnex::Runner`** — `harnex run` (spawn, foreground/detach/tmux)
- **`Harnex::Sender`** — `harnex send` (resolve target, inject text)
- **`Harnex::Status`** — `harnex status` (list sessions)
- **`Harnex::Waiter`** — `harnex wait` (block until exit or state)
- **`Harnex::Stopper`** — `harnex stop` (send stop sequence)
- **`Harnex::Session`** — PTY lifecycle, HTTP API server, registry
- **`Harnex::SessionState`** — state machine (prompt/busy/blocked)
- **`Harnex::Inbox`** — per-session message queue with delivery thread
- **`Harnex::ApiServer`** — per-session HTTP control API
- **`Harnex::Pane`** — `harnex pane` (capture a tmux pane snapshot)

## Adapter contract

Adapters live in `lib/harnex/adapters/` and must implement:

- `base_command` — CLI args to launch the agent

May override:

- `input_state(screen_text)` — parse screen to detect prompt/busy/blocked
- `build_send_payload(...)` — build injection payload with submit behavior
- `inject_exit(writer)` — send the adapter-specific stop sequence
- `infer_repo_path(argv)` — extract repo path from CLI args
- `send_wait_seconds(submit:, enter_only:)` — how long to wait for sendable state
- `wait_for_sendable_state?(state, submit:, enter_only:)` — whether a state is sendable
- `wait_for_sendable(screen_snapshot_fn, submit:, enter_only:, force:)` — orchestrate send-readiness waiting

## If you are running inside harnex

Check `$HARNEX_ID` and `$HARNEX_SESSION_CLI` to confirm. You can use
`harnex send`, `harnex status`, and `harnex wait` to coordinate with
peer sessions. See `skills/harnex/SKILL.md` for full usage patterns.

When starting a peer CLI session on the user's behalf, default to a
visible interactive tmux session via `harnex run <cli> --tmux` so the
user can inspect the peer's work live.

Use hidden/background modes only when the user explicitly asks for them
or when visibility is not wanted. In particular:

- prefer `--tmux` over a hidden foreground PTY for delegated peer work
- use plain foreground `harnex run` only when the current terminal is the
  intended UI for that peer
- use `--detach` only when the user explicitly wants headless/background
  execution

Before delegating work over harnex, define the return channel first.
Preferred pattern: tell the peer to send its final result back to your own
`$HARNEX_ID` with `harnex send`. Do not rely on detached logs or tmux pane
capture as the primary way to collect the answer.

## Development notes

- Ruby 3.x, stdlib only (no gems)
- File watching: inotify on Linux, stat-polling fallback on macOS/other
- Run tests: `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`
