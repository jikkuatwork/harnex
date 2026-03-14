# Harnex — Agent Orientation

This file helps AI agents (Claude, Codex, etc.) understand the harnex
codebase quickly. If you are an agent reading this, start here.

## What is harnex?

A PTY harness that wraps terminal AI agents and adds a local control plane
for discovery, messaging, and coordination. It does not change the wrapped
agent's UI — it runs alongside it.

## Repo layout

```
bin/harnex                          CLI entry point
lib/harnex.rb                      Main implementation (~1900 lines)
lib/harnex/adapters/base.rb        Adapter base class
lib/harnex/adapters/codex.rb       Codex adapter (prompt detection, submit)
lib/harnex/adapters/claude.rb      Claude adapter (trust prompt, submit)
skills/harnex/SKILL.md             Skill file for Claude/Codex integration
koder/STATE.md                     Project state tracker
koder/plans/                       Implementation plans
```

## Key classes (all in lib/harnex.rb)

- **`Harnex::CLI`** — top-level command dispatch
- **`Harnex::Runner`** — `harnex run` (spawn, foreground/detach/tmux)
- **`Harnex::Sender`** — `harnex send` (resolve target, inject text)
- **`Harnex::Status`** — `harnex status` (list sessions)
- **`Harnex::Waiter`** — `harnex wait` (block until exit)
- **`Harnex::Session`** — PTY lifecycle, HTTP API server, registry
- **`Harnex::SessionState`** — state machine (prompt/busy/blocked)
- **`Harnex::Inbox`** — per-session message queue with delivery thread
- **`Harnex::Message`** — queued message struct
- **`Harnex::FileChangeHook`** — inotify-based file watcher
- **`Harnex::LinuxInotify`** — raw inotify via Fiddle

## Adapter contract

Adapters live in `lib/harnex/adapters/` and must implement:

- `base_command` — CLI args to launch the agent
- `input_state(screen_text)` — parse screen to detect prompt/busy/blocked
- `build_send_payload(...)` — build injection payload with submit behavior
- `infer_repo_path(argv)` — extract repo path from CLI args

## How sessions work

1. `harnex run` spawns the agent under a PTY
2. Picks a deterministic port from repo hash + session ID
3. Starts a local HTTP server (`/status`, `/send`, `/messages/:id`)
4. Writes a registry JSON file to `~/.local/state/harnex/sessions/`
5. Monitors PTY output, feeds it to the adapter for state detection
6. Inbox thread delivers queued messages when adapter reports prompt

## How messaging works

- `harnex send` resolves target via registry, POSTs to its HTTP API
- If agent is at prompt: immediate injection (HTTP 200)
- If agent is busy: queued in inbox (HTTP 202), auto-delivered later
- Cross-session sends get a `[harnex relay ...]` header automatically
- `--context` on `harnex run` sets an initial prompt on spawn

## If you are running inside harnex

Check `$HARNEX_ID` and `$HARNEX_SESSION_CLI` to confirm. You can use
`harnex send`, `harnex status`, and `harnex wait` to coordinate with
peer sessions. See `skills/harnex/SKILL.md` for full usage patterns.

## More details

See [TECHNICAL.md](TECHNICAL.md) for the HTTP API, adapter
contract, state machine, concurrency model, and known issues.

## Development notes

- Ruby 3.x, stdlib only (no gems)
- Single-file implementation (refactor planned, see koder/plans/)
- No test suite yet (planned)
- Linux-only for file watching (inotify via Fiddle)
