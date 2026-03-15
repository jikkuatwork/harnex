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
lib/harnex/commands/             Command implementations (run, send, wait, exit, status)
lib/harnex/runtime/              Session, state machine, inbox, API server
lib/harnex/adapters/             Adapter base + CLI-specific adapters
lib/harnex/linux_inotify.rb      inotify via Fiddle
test/                            Minitest suite (84 tests)
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
- **`Harnex::Exiter`** — `harnex exit` (send exit sequence)
- **`Harnex::Session`** — PTY lifecycle, HTTP API server, registry
- **`Harnex::SessionState`** — state machine (prompt/busy/blocked)
- **`Harnex::Inbox`** — per-session message queue with delivery thread
- **`Harnex::ApiServer`** — per-session HTTP control API

## Adapter contract

Adapters live in `lib/harnex/adapters/` and must implement:

- `base_command` — CLI args to launch the agent

May override:

- `input_state(screen_text)` — parse screen to detect prompt/busy/blocked
- `build_send_payload(...)` — build injection payload with submit behavior
- `exit_sequence` — text to send for clean exit
- `infer_repo_path(argv)` — extract repo path from CLI args

## If you are running inside harnex

Check `$HARNEX_ID` and `$HARNEX_SESSION_CLI` to confirm. You can use
`harnex send`, `harnex status`, and `harnex wait` to coordinate with
peer sessions. See `skills/harnex/SKILL.md` for full usage patterns.

## Development notes

- Ruby 3.x, stdlib only (no gems)
- Linux-only for file watching (inotify via Fiddle)
- Run tests: `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`
