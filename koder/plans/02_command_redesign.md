# Command & API Redesign Plan

Date: 2026-03-15

## Goal

Redesign the harnex CLI surface and HTTP API for consistency, removing all
legacy patterns. There are no existing users — this is a clean break.

## Design principles

1. Every command is `harnex <verb>`, operating on sessions
2. JSON on stdout, human text on stderr — no exceptions
3. Uniform flags: `--id`, `--repo`, `--timeout` mean the same everywhere
4. Exit codes: 0 success, 1 error, 2 usage, 124 timeout
5. No implicit behavior: bare `harnex` shows help
6. No legacy aliases

## Exit codes (all commands)

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Runtime error |
| 2 | Usage / parse error (OptionParser rescue in bin/harnex) |
| 124 | Timeout |

## Command surface

```
harnex run <cli> [options] [--] [cli-args...]
harnex send --id ID [options] [text...]
harnex wait --id ID [options]
harnex stop --id ID [options]
harnex status [options]
harnex help [command]
```

### `harnex` (no args)

Show help text. Do NOT spawn a session.

### `harnex run <cli> [options] [--] [cli-args...]`

```
<cli>              Agent to launch (required: claude, codex)

--id ID            Session identifier (default: cli name)
--detach           Run in background, return JSON on stdout
--tmux [NAME]      Run in a tmux window (implies --detach)
--host HOST        Bind address for control API (default: 127.0.0.1)
--port PORT        Force a specific control API port
--watch PATH       Auto-send file-change hook on modification
--context TEXT     Inject as initial prompt (prepends session header)
--timeout SECS     For --detach: max seconds to wait for registration (default: 5)
-h, --help
```

Changes from current:
- `<cli>` is **required** — remove `DEFAULT_CLI` fallback from dispatch
- Print selected port to stderr: `harnex: listening on 127.0.0.1:43217`
- `--timeout` for detach registration wait (replaces hardcoded 5s)
- Remove `--label` alias
- Remove `Launcher` alias class

### `harnex send --id ID [options] [text...]`

```
--id ID            Target session (required, no env fallback)
--repo PATH        Resolve session from repo root
--cli CLI          Filter by cli type
--message TEXT     Message text (alternative to positional args)
--no-submit        Inject text without pressing Enter
--submit-only      Press Enter without injecting text (was: --enter)
--force            Send even if agent isn't at prompt
--no-wait          Return queued message_id immediately (was: --async)
--relay            Force relay header
--no-relay         Suppress auto relay header
--port PORT        Direct port mode (bypass registry)
--token TOKEN      Auth token for direct port mode
--host HOST        Override host for direct port mode
--timeout SECS     How long to wait for session/delivery (default: 30)
--verbose          Print lookup/delivery details to stderr (was: --debug)
-h, --help
```

Changes from current:
- `--id` is **required** — remove `configured_id` fallback
- Remove `--status` (use `harnex status --id ID` instead)
- `--enter` → `--submit-only` (describes intent, not keystroke)
- `--async` → `--no-wait` (matches --no-submit pattern)
- `--wait SECONDS` → `--timeout SECS` (uniform naming)
- `--debug` → `--verbose`
- Remove `--label`
- Stdin: only read if stdin is a pipe (not a TTY). If TTY and no text → error:
  `harnex send: no message provided (use --message, positional args, or pipe)`

### `harnex wait --id ID [options]`

```
--id ID            Session to wait on (required)
--until STATE      Wait for state (e.g. "prompt") instead of exit
--repo PATH        Resolve session from repo root
--timeout SECS     Maximum wait time (default: unlimited)
-h, --help
```

Already clean from recent work. No changes needed.

### `harnex stop --id ID [options]`

Renamed from `exit`.

```
--id ID            Session to stop (required)
--repo PATH        Resolve session from repo root
--cli CLI          Filter by cli type
-h, --help
```

Changes from current:
- Command renamed `exit` → `stop`
- Class renamed `Exiter` → `Stopper`
- Parse response body as JSON, re-serialize (don't print raw body)
- If response isn't valid JSON, wrap in error object

### `harnex status [options]`

```
--id ID            Show specific session
--repo PATH        Filter to repo root (default: current repo)
--all              Show all repos
--json             Output as JSON array instead of table
-h, --help
```

Changes from current:
- Add `--id` for single-session lookup
- Add `--json` for machine-readable output

### `harnex help [command]`

Same as current. Also triggered by `harnex -h` / `harnex --help`.

## HTTP API changes

| Endpoint | Change |
|---|---|
| `POST /exit` | Rename to `POST /stop` |
| `POST /send` (inbox full) | Return **503** instead of 409 |

All other endpoints unchanged.

## Things to remove

| What | Where | Why |
|---|---|---|
| `--label` flag | run.rb, send.rb | Legacy alias, not in other commands |
| `--status` flag on send | send.rb | PoLS: send shouldn't read |
| `--enter` flag | send.rb | Replaced by `--submit-only` |
| `--async` flag | send.rb | Replaced by `--no-wait` |
| `--debug` flag | send.rb | Replaced by `--verbose` |
| `Launcher` alias | run.rb:312 | Cruft |
| `DEFAULT_CLI` usage in dispatch | cli.rb:9-10 | Bare harnex shows help now |
| `configured_id` method | core.rb:55-60 | No env-based ID fallback |
| `CXW_*` env fallbacks | core.rb:9-22 | All `legacy:` params in `env_value` |
| `HARNEX_LABEL` env | core.rb:57 | Legacy |
| `HARNEX_SEND_WAIT` env | send.rb:54 | Use `--timeout` |
| `HARNEX_PORT` env | run.rb:38 | Use `--port` |
| `env_value` legacy param | core.rb:11 | No legacy vars left |
| `ensure_option_value!` | core.rb:89-97 | Rethink — see below |

## `ensure_option_value!` fix

Current behavior rejects any value starting with `-`. This breaks
`--message "-1 is the answer"`.

New behavior: only reject if value is a known harnex flag (starts with `--`
and matches a registered option name). Single `-` or negative numbers pass
through. Implement as a simple check against a set of known flag prefixes,
or just remove the check entirely — OptionParser already handles missing
arguments for options that take values.

For commands using OptionParser (send, wait, stop, status): remove
`ensure_option_value!` calls entirely. OptionParser handles this.

For `run` (manual parsing): keep a minimal check that only rejects
strings matching `--<known-option>` patterns.

## Implementation phases

### Phase 1: Renames and removals

1. Rename `exit` → `stop` everywhere:
   - `lib/harnex/commands/exit.rb` → `lib/harnex/commands/stop.rb`
   - Class `Exiter` → `Stopper`
   - CLI dispatch: `"exit"` → `"stop"`, `Exiter` → `Stopper`
   - Help text references
   - API endpoint `POST /exit` → `POST /stop`
   - `api_server.rb`: update route
   - `session.rb`: rename `inject_exit` → `inject_stop`
   - Test file: `exit_test.rb` → `stop_test.rb`, class `ExiterTest` → `StopperTest`
2. Remove `Launcher` alias from run.rb
3. Remove `--label` from run.rb and send.rb
4. Remove `DEFAULT_CLI` auto-spawn: cli.rb `when nil` → show help
5. Remove `CXW_*` env fallbacks: simplify `env_value` to just `ENV[name] || default`
6. Remove `configured_id` — commands that need `--id` require it explicitly
7. Remove `HARNEX_SEND_WAIT`, `HARNEX_PORT`, `HARNEX_LABEL` env lookups

### Phase 2: Flag renames on send

1. `--enter` → `--submit-only`
2. `--async` → `--no-wait`
3. `--debug` → `--verbose`
4. `--wait SECONDS` → `--timeout SECS`
5. Remove `--status`
6. Remove `ensure_option_value!` from OptionParser-based commands
7. Simplify `ensure_option_value!` for run.rb manual parser (or remove)

### Phase 3: Output consistency

1. `harnex stop`: parse response as JSON, re-serialize
2. `harnex status`: add `--id` and `--json` flags
3. `harnex run`: print port to stderr on foreground start
4. `harnex run --detach`: respect `--timeout` for registration wait
5. `harnex send`: stdin only from pipe, not TTY
6. API: inbox full → 503 instead of 409

### Phase 4: Update tests

1. Rename exit tests → stop tests
2. Update all test assertions for new flag names
3. Add tests for:
   - Bare `harnex` returns help (exit 0)
   - `harnex send` without `--id` raises error
   - `harnex send --message "-1"` works (no false rejection)
   - `harnex status --json` outputs valid JSON array
   - `harnex status --id` filters correctly
   - `harnex stop` parses JSON response
4. Verify full suite passes

### Phase 5: Cleanup

1. Update help text in all commands
2. Update `CLAUDE.md` repo layout and class list
3. Update `TECHNICAL.md` if it references old flag names or endpoints
4. Update `koder/STATE.md`
5. Update `skills/harnex/SKILL.md` if it references old commands

## Verification

```bash
# Syntax check
ruby -c bin/harnex
ruby -c lib/harnex.rb

# Full test suite
ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'

# Help text smoke test
bin/harnex
bin/harnex help run
bin/harnex help send
bin/harnex help wait
bin/harnex help stop
bin/harnex help status
```

## Done criteria

- No `CXW_*`, `--label`, `--status` (on send), `Launcher`, `DEFAULT_CLI`
  auto-spawn, or `configured_id` remain in the codebase
- `exit` → `stop` rename complete (command, API, class, tests)
- `--enter` → `--submit-only`, `--async` → `--no-wait`, `--debug` → `--verbose`
- All JSON output goes to stdout, all human messages to stderr
- Exit codes are 0/1/2/124 consistently
- Test suite passes with no failures
- Help text is accurate and complete
