# Plan 08: Pane Capture for Tmux Sessions

Issue: #11
Date: 2026-03-16

## ONE THING

Add `harnex pane` — a clean screen snapshot command for tmux-backed sessions.

## Problem

The transcript log captures raw PTY output with escape sequences. For a
quick "what does the screen look like now?" diagnostic, `tmux capture-pane`
gives clean text instantly. There's no harnex command to surface this.

## Design

### CLI command: `harnex pane --id <session>`

Runs `tmux capture-pane -t <window> -p` and prints the result. The tmux
window name is the session ID (the default set by `run_in_tmux`).

**Options:**
- `--id ID` (required) — session ID
- `--repo PATH` — resolve using this repo root (default: cwd)
- `--cli CLI` — filter by CLI type
- `--lines N` — capture last N lines (omit for full pane)
- `--json` — wrap output in JSON with metadata
- `-h, --help` — show help

**Behavior:**
1. Resolve session from registry (must be live).
2. Check that `tmux` is available and the window exists:
   `tmux has-session -t <window>` (exit 0 = exists).
3. Capture: `tmux capture-pane -t <window> -p` (full pane) or
   `tmux capture-pane -t <window> -p -S -N` (last N lines).
4. Print text to stdout. With `--json`, wrap as:
   `{"ok":true,"id":"...","captured_at":"...","lines":<n>,"text":"..."}`
5. Exit 0 on success, 1 on error (not tmux, window not found, etc.).

### API endpoint: `GET /pane`

On the session's HTTP API server. Runs `tmux capture-pane` via the session
process and returns JSON. Only works if the session was launched via
`--tmux`. Returns 409 if not a tmux session (no window name known).

**Implementation detail:** The session needs to know its tmux window name.
Add an optional `tmux_window` parameter to `Session#initialize` and pass it
through from `run_in_tmux`. Store it on the session; the API server checks
`session.tmux_window` to decide if `/pane` is available.

Wait — the `pane` CLI command doesn't go through the session API, it shells
out to `tmux capture-pane` directly. The API endpoint is the one that needs
the window name on the session object. But for the CLI command, we can
derive the window name from the session ID (since `run_in_tmux` defaults to
`@options[:tmux_name] || @options[:id]`).

**Revised approach — keep it simple:**
- CLI `harnex pane` shells out to `tmux capture-pane` using the session ID
  as the window target. No API call needed. This works for tmux sessions
  and fails gracefully for non-tmux sessions (tmux returns error).
- API `GET /pane` is **deferred** — it requires plumbing the window name
  into the session object, which is more invasive. Not needed for the core
  use case (supervisor diagnosing a stuck session from the terminal).

### Structural changes

**New file: `lib/harnex/commands/pane.rb`**
- `Harnex::Pane` class following the pattern of `Logs`/`Status`
- OptionParser for `--id`, `--repo`, `--cli`, `--lines`, `--json`, `--help`
- `resolve_session` — find live session in registry
- `capture` — shell out to `tmux capture-pane`
- `run` — orchestrate and print

**Modified: `lib/harnex/cli.rb`**
- Add `when "pane"` dispatch
- Add to `help` method
- Add to `usage` text

**Modified: `lib/harnex.rb`**
- Require the new command file

**New file: `test/harnex/commands/pane_test.rb`**
- Test option parsing
- Test error when `--id` missing
- Test error when session not found
- Test error when tmux not available (stub `system`)
- Test successful capture (stub tmux output)
- Test `--lines` flag passes `-S -N` to tmux
- Test `--json` wraps output

### Tests

Follow the patterns in `test/harnex/commands/logs_test.rb`:
- Stub registry reads via `Harnex.stub` or temp dirs
- Stub `tmux` calls — don't require actual tmux in CI
- Test each flag independently

## Acceptance criteria

- [ ] `harnex pane --id <session>` prints clean screen text for a tmux session
- [ ] `--lines N` limits capture to last N lines
- [ ] `--json` returns JSON with id, captured_at, text
- [ ] Error message when session not found
- [ ] Error message when session is not tmux-backed (tmux window doesn't exist)
- [ ] `harnex help pane` shows usage
- [ ] `harnex pane --help` shows usage
- [ ] Tests pass
- [ ] Existing tests still pass (no regressions)

## Deferral list

- `GET /pane` API endpoint (needs tmux_window on Session object)
- Storing tmux window name in registry
- Colorized/formatted pane output
- Continuous pane follow mode (like `logs --follow`)
- Pane capture for non-tmux sessions (not possible without tmux)
