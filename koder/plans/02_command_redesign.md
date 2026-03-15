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

## Generic adapter and binary validation

### Problem

Currently `harnex run` only accepts CLIs with a registered adapter (`claude`,
`codex`). Any other CLI name is rejected. And if a registered CLI's binary
isn't installed, `PTY.spawn` raises a cryptic `Errno::ENOENT: No such file
or directory - fork failed`.

### Solution: two changes

**1. Generic adapter for unknown CLIs**

If the CLI name isn't in the adapter registry, fall back to a `Generic`
adapter instead of raising an error. This lets `harnex run opencode`,
`harnex run droid`, `harnex run aider`, etc. work out of the box.

```ruby
# adapters/generic.rb
class Generic < Base
  def initialize(cli_name, extra_args = [])
    @cli_name = cli_name
    super(cli_name, extra_args)
  end

  def base_command
    [@cli_name]
  end
end
```

Update `Adapters.build`:

```ruby
def build(key, extra_args = [])
  adapter_class = registry[key.to_s]
  if adapter_class
    adapter_class.new(extra_args)
  else
    Generic.new(key.to_s, extra_args)
  end
end
```

The generic adapter inherits all Base defaults:
- `input_state` → always `:unknown` (no prompt detection)
- `build_send_payload` → raw text injection
- `exit_sequence` → `/exit\n`
- `infer_repo_path` → `Dir.pwd`

Known adapters (claude, codex) still get their smart prompt detection
and submit behavior. New adapters can be added later for better support.

`Adapters.supported` should be renamed or supplemented with
`Adapters.known` to distinguish "has a dedicated adapter" from
"can be launched". Help text should say:

```
CLIs with smart prompt detection: claude, codex
Any other CLI name is launched with generic wrapping.
```

**2. Binary existence check before spawn**

In `Session#run`, before `PTY.spawn`, check if the binary exists:

```ruby
def validate_binary!
  binary = command.first
  return if binary.include?("/") && File.executable?(binary)

  resolved = which(binary)
  return if resolved

  raise Harnex::BinaryNotFound,
    "\"#{binary}\" not found — is it installed and on your PATH?"
end

def which(name)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
    path = File.join(dir, name)
    return path if File.executable?(path) && !File.directory?(path)
  end
  nil
end
```

Define `Harnex::BinaryNotFound < RuntimeError` in core.rb.

This gives a clear error:

```
harnex: "droid" not found — is it installed and on your PATH?
```

## Random session IDs

When `--id` is not specified, generate a random two-word ID like `blue-cat`.

### Word lists

Define two arrays in `core.rb`, 20 words each:

```ruby
ID_ADJECTIVES = %w[
  bold blue calm cool dark dry fast gold gray green
  keen loud mint pale pink red shy slim soft warm
].freeze

ID_NOUNS = %w[
  ant bat bee cat cod cow cub doe elk fox
  hen jay kit owl pug ram ray seal wasp yak
].freeze
```

### Generation

```ruby
def generate_id(repo_root)
  taken = active_session_ids(repo_root)
  ID_ADJECTIVES.product(ID_NOUNS).shuffle.each do |adj, noun|
    candidate = "#{adj}-#{noun}"
    return candidate unless taken.include?(candidate)
  end
  # Fallback if all 400 combos taken (unlikely)
  "session-#{SecureRandom.hex(4)}"
end

def active_session_ids(repo_root)
  active_sessions(repo_root).map { |s| s["id"].to_s.downcase }.to_set
end
```

### Where it's used

Only in `harnex run` when `--id` is omitted:

```ruby
# In Runner#run, after cli_name is resolved:
@options[:id] ||= Harnex.generate_id(repo_root)
```

All other commands (`send`, `wait`, `stop`) still **require** `--id`.
The generated ID is printed to stderr: `harnex: session blue-cat on 127.0.0.1:43217`

## Session description (`--description`)

### Flag

Add `--description TEXT` to `harnex run`:

```
--description TEXT  Short description of what this session is doing
```

### Storage

- Stored in the registry JSON as `"description"` field
- Exposed in `/status` API response as `"description"`
- Passed to child as `HARNEX_DESCRIPTION` env var

### In session.rb child_env:

```ruby
def child_env
  env = {
    "HARNEX_SESSION_ID" => session_id,
    "HARNEX_SESSION_CLI" => adapter.key,
    "HARNEX_ID" => id,
    "HARNEX_SESSION_REPO_ROOT" => repo_root
  }
  env["HARNEX_DESCRIPTION"] = description if description
  env
end
```

### In `harnex status` table:

Add a DESC column (truncated to 30 chars in table mode, full in --json):

```
ID        CLI     PID    PORT   AGE   STATE   DESC
blue-cat  codex   12345  43217  3m    prompt  implement auth module
red-fox   claude  12346  43218  12m   busy    fix payment bugs
```

### Self-discovery from inside a session

The wrapped agent reads env vars to know its own identity:

```
$HARNEX_ID          → "blue-cat"
$HARNEX_DESCRIPTION → "implement auth module"
```

These are already set (except HARNEX_DESCRIPTION which we add).
The agent can also query its own session's API via the port in
the registry, or use `harnex status --id $HARNEX_ID --json` to
get full metadata.

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

--id ID            Session identifier (default: random two-word, e.g. "blue-cat")
--description TEXT Short description of what this session does
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
- `--id` defaults to random two-word ID (e.g. "blue-cat"), not cli name
- Add `--description` — stored in registry, exposed in API, passed as env var
- Print session info to stderr: `harnex: session blue-cat on 127.0.0.1:43217`
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

### Phase 0: Generic adapter, binary check, random IDs, --description

1. Add `Harnex::BinaryNotFound < RuntimeError` to `core.rb`
2. Add `adapters/generic.rb` — subclass of Base, takes cli name as command
3. Update `Adapters.build` to fall back to `Generic` instead of raising
4. Rename `Adapters.supported` → `Adapters.known` (adapters with smart
   detection); add `Adapters.supported?` that returns true for any string
5. Update help text: "CLIs with smart prompt detection: claude, codex.
   Any other CLI name is launched with generic wrapping."
6. Add `Session#validate_binary!` with `which()` helper, called at top
   of `Session#run` before `PTY.spawn`
7. Add `ID_ADJECTIVES` and `ID_NOUNS` arrays to `core.rb` (20 words each)
8. Add `generate_id(repo_root)` and `active_session_ids(repo_root)` to `core.rb`
3. In `Runner#run`: replace `@options[:id] ||= Harnex.default_id(cli_name)` with
   `@options[:id] ||= Harnex.generate_id(repo_root)` — note: repo_root must be
   resolved before ID generation, so reorder if needed
4. Add `--description TEXT` to Runner's option parsing (both manual parser and
   `--description=TEXT` form)
5. Store `@options[:description]` in Runner, pass to Session constructor
6. In `Session#initialize`: accept `description:` kwarg, store as `@description`
7. In `Session#child_env`: add `"HARNEX_DESCRIPTION" => @description` when present
8. In `Session#status_payload`: add `description: @description` when present
9. In `Session#registry_payload`: description is included via status_payload
10. In `Status#table_row`: add DESC column showing `session["description"]`
    (truncate to 30 chars in table, full in --json)
11. Print session info to stderr in foreground mode:
    `warn("harnex: session #{id} on #{host}:#{port}")`
12. Tests:
    - `Generic` adapter uses cli name as command
    - `Adapters.build("opencode")` returns Generic, not raises
    - `validate_binary!` raises BinaryNotFound for missing binary
    - `validate_binary!` passes for existing binary (e.g. "ruby")
    - `generate_id` returns adjective-noun format
    - `generate_id` avoids collision with active sessions
    - `generate_id` falls back to hex when all combos taken (mock)
    - `--description` appears in status_payload
    - `HARNEX_DESCRIPTION` appears in child_env

### Phase 0b: Adapter contract cleanup

Move leaked runtime logic behind the adapter boundary so that a new
adapter can fully control exit and send-readiness behavior.

1. **`exit_sequence` → `inject_exit(writer)`**: Currently session.rb
   calls `adapter.exit_sequence` to get text, then does its own
   `inject_sequence`. Instead, the adapter should own the full exit
   flow. Rename to `inject_exit(writer)` — base impl writes `/exit\n`,
   but a future adapter could send Ctrl+C, a signal, or multi-step.

   In `base.rb`:
   ```ruby
   def inject_exit(writer)
     writer.write("/exit\n")
     writer.flush
   end
   ```

   In `session.rb`, replace:
   ```ruby
   def inject_exit
     sequence = adapter.exit_sequence
     inject_sequence([{ text: sequence, newline: false }])
   end
   ```
   With:
   ```ruby
   def inject_stop
     raise "session is not running" unless pid && Harnex.alive_pid?(pid)
     @inject_mutex.synchronize do
       adapter.inject_exit(@writer)
       @state_machine.force_busy!
     end
     { ok: true, signal: "exit_sequence_sent" }
   end
   ```

2. **Move `wait_for_sendable_snapshot` into adapter**: Currently the
   polling loop (sleep, deadline, state check) lives in session.rb
   with the adapter providing `send_wait_seconds` and
   `wait_for_sendable_state?`. Move the whole method to base adapter
   so subclasses can override the strategy entirely.

   In `base.rb`:
   ```ruby
   def wait_for_sendable(screen_snapshot_fn, submit:, enter_only:, force:)
     return screen_snapshot_fn.call if force
     snapshot = screen_snapshot_fn.call
     wait_secs = send_wait_seconds(submit: submit, enter_only: enter_only).to_f
     return snapshot unless wait_secs.positive?

     deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_secs
     state = input_state(snapshot)
     while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline &&
           wait_for_sendable_state?(state, submit: submit, enter_only: enter_only)
       sleep 0.05
       snapshot = screen_snapshot_fn.call
       state = input_state(snapshot)
     end
     snapshot
   end
   ```

   Session.rb calls: `adapter.wait_for_sendable(method(:screen_snapshot), ...)`
   This keeps the base behavior identical but lets a future adapter
   (e.g. one that checks an HTTP health endpoint) override entirely.

3. **Remove `submit_bytes` from public contract**: It's only used inside
   `build_send_payload`. Keep it as a private/protected helper in Base.
   Not part of the adapter interface.

4. **Document the adapter contract** in `base.rb` with a comment block:

   ```ruby
   # Adapter contract — subclasses MUST implement:
   #   base_command          → Array[String]  CLI args to spawn
   #
   # Subclasses MAY override:
   #   input_state(text)     → Hash           Parse screen for state
   #   build_send_payload    → Hash           Build injection payload
   #   inject_exit(writer)   → void           Send exit sequence
   #   infer_repo_path(argv) → String         Extract repo from CLI args
   #   wait_for_sendable     → String         Wait for ready state
   ```

5. Tests:
   - Base adapter `inject_exit` writes `/exit\n`
   - Codex/Claude adapters inherit or override correctly
   - `wait_for_sendable` returns immediately when force=true
   - Custom adapter can override `inject_exit` with different behavior

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

- Any CLI name works via generic adapter; known adapters get smart detection
- Missing binary gives clear error: `"X" not found — is it installed and on your PATH?`
- Random two-word IDs generated when `--id` omitted from `harnex run`
- `--description` stored in registry, exposed in API and env vars
- No `CXW_*`, `--label`, `--status` (on send), `Launcher`, `DEFAULT_CLI`
  auto-spawn, or `configured_id` remain in the codebase
- `exit` → `stop` rename complete (command, API, class, tests)
- `--enter` → `--submit-only`, `--async` → `--no-wait`, `--debug` → `--verbose`
- All JSON output goes to stdout, all human messages to stderr
- Exit codes are 0/1/2/124 consistently
- Test suite passes with no failures
- Help text is accurate and complete
