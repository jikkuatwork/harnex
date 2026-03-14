# Harnex State

Updated: 2026-03-14

## Current repo state

### Architecture

- Single file: `lib/harnex.rb` (~1880 lines)
- Adapters: `lib/harnex/adapters/{base,codex,claude}.rb`
- Skill: `skills/harnex/SKILL.md` (symlinked to `~/.claude/skills/` and `~/.codex/skills/`)
- CLI entry: `bin/harnex`
- Session registry: `~/.local/state/harnex/sessions/`
- Exit status: `~/.local/state/harnex/exits/<id>.json`
- Headless logs: `~/.local/state/harnex/logs/<id>.log`

### Features

- **ID-based addressing** — sessions addressed by unique `--id` (not label)
- **State machine** — `SessionState` tracks prompt/busy/blocked/unknown via
  adapter screen parsing, condvar-based blocking
- **Inbox queue** — per-session FIFO with background delivery thread; messages
  queue when busy (HTTP 202), auto-deliver on prompt return
- **Detached sessions** — `--detach` for headless, `--tmux [NAME]` for tmux
  windows with custom terse names
- **Wait** — `harnex wait --id X` blocks until session exits, returns exit code
- **Relay headers** — automatic `[harnex relay from=... id=...]` on cross-session sends
- **File watch hooks** — inotify-based, debounced
- **Adapters** — codex (prompt detection, multi-step inject) and claude
  (trust prompt detection)

### Recent changes (this session)

1. State machine + inbox queue (SessionState, Message, Inbox classes)
2. Label → ID rename (`--label` kept as deprecated alias)
3. `--detach` and `--tmux [NAME]` for background session spawning
4. `harnex wait` subcommand
5. Exit status persistence (`exits/<id>.json`)
6. Skill file created in repo, symlinked to `~/.claude/` and `~/.codex/`
7. README and docs updated

### Key commits

- `f54376a` — Track state handoff and ignore tmp artifacts
- `65b3e11` — Improve relay sends and document live discussion workflow
- `314f3a7` — Add file watcher
- `c436bba` — Support shared labels across codex and claude

## Testing the supervisor workflow

Start both sessions under harnex:

```bash
# Terminal 1 — supervisor (you interact here)
harnex run claude --id supervisor

# The supervisor can then spawn workers:
harnex run codex --id test-worker --tmux cx-t1
harnex send --id test-worker --message "Review this project and give feedback"
harnex wait --id test-worker
```
