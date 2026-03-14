# Harnex Refactor Plan

Date: 2026-03-14

## Goal

Refactor `lib/harnex.rb` into smaller, cohesive files, keep the CLI behavior
stable, and add a small but meaningful automated test suite using standard
library tooling.

## Constraints

- Keep the public command surface the same:
  - `harnex`
  - `harnex run`
  - `harnex send`
  - `harnex status`
  - `harnex wait`
- Keep adapter behavior intact unless fixing clearly broken cases.
- Prefer stdlib-only test tooling (`minitest`) so the repo stays dependency-light.
- Avoid a large protocol redesign during the same pass.

## Proposed file layout

```text
bin/harnex
lib/harnex.rb
lib/harnex/version.rb                  # optional only if useful
lib/harnex/core.rb                     # constants + module helpers
lib/harnex/linux_inotify.rb
lib/harnex/adapters.rb
lib/harnex/adapters/base.rb
lib/harnex/adapters/codex.rb
lib/harnex/adapters/claude.rb
lib/harnex/cli.rb
lib/harnex/commands/run.rb
lib/harnex/commands/send.rb
lib/harnex/commands/status.rb
lib/harnex/commands/wait.rb
lib/harnex/runtime/session_state.rb
lib/harnex/runtime/message.rb
lib/harnex/runtime/inbox.rb
lib/harnex/runtime/session.rb
lib/harnex/runtime/file_change_hook.rb
lib/harnex/runtime/api_server.rb
test/test_helper.rb
test/harnex/core_test.rb
test/harnex/adapters/codex_test.rb
test/harnex/adapters/claude_test.rb
test/harnex/commands/send_test.rb
test/harnex/commands/run_test.rb       # only if parser extraction is testable
test/harnex/runtime/inbox_test.rb
```

## Refactor strategy

### Phase 1: Freeze behavior with a minimal test harness

Create `test/test_helper.rb` with:

- `require "minitest/autorun"`
- `require_relative "../lib/harnex"`
- small helpers for temp dirs, fake sessions, and environment isolation

Initial smoke tests before moving code:

- relay header formatting
- ID normalization / registry path rules
- adapter prompt detection
- sender text resolution and relay decision logic

This gives a baseline before the file split starts.

### Phase 2: Split the monolith by responsibility

Move code out of `lib/harnex.rb` in this order:

1. `core.rb`
   - env/config helpers
   - repo resolution
   - registry path helpers
   - relay formatting
   - port allocation
   - `WatchConfig`

2. `linux_inotify.rb`
   - isolate Linux-specific Fiddle logic

3. `runtime/*`
   - `SessionState`
   - `Message`
   - `Inbox`
   - `Session`
   - `FileChangeHook`
   - `ApiServer`

4. `commands/*`
   - `Run`
   - `Send`
   - `Status`
   - `Wait`

5. `cli.rb`
   - top-level command dispatch only

Then reduce `lib/harnex.rb` to a lightweight loader plus module definition.

### Phase 3: Make the Ruby more idiomatic while preserving behavior

Targeted cleanup during extraction:

- Put command classes under `Harnex::Commands`.
- Put runtime classes under `Harnex::Runtime`.
- Keep `Harnex::CLI` as the entry point.
- If compatibility is useful, add aliases:
  - `Harnex::Runner = Harnex::Commands::Run`
  - `Harnex::Sender = Harnex::Commands::Send`
  - `Harnex::Status = Harnex::Commands::Status`
  - `Harnex::Waiter = Harnex::Commands::Wait`
- Replace broad helper sprawl with smaller modules or classes where it reduces
  coupling, but avoid abstracting for its own sake.
- Keep command parsing local to each command class.

## Tests to add

### Core behavior

- `format_relay_message`
- `current_session_context`
- `normalize_id`
- `id_key`
- `registry_path`

### Adapters

Codex:

- detects prompt when prompt marker exists
- stays non-sendable when session output does not show prompt
- builds multi-step submit payload with delayed Enter

Claude:

- detects workspace trust prompt as blocked
- allows `--enter` for workspace trust prompt
- detects prompt mode from insert/prompt markers

### Sender

- adds relay header only for cross-session sends
- does not double-wrap an existing relay header
- keeps `--enter` requests empty
- reports ambiguous and missing session cases cleanly

### Inbox / queue

- immediate delivery when prompt is ready and queue is empty
- queued delivery when not ready
- failure recording when injection raises
- `message_status` shape

## Bugs worth fixing during the refactor

These are worth treating as part of the same pass because they sit in the code
being touched anyway:

1. `harnex send --port` currently cannot authenticate because the token is only
   available from the registry path, not from CLI input.
2. Exit files and headless logs are keyed only by `id`, so they can collide
   across repos or repeated runs.
3. `harnex wait` should be able to return a recent exit record even if the live
   registry entry is already gone.
4. On-disk session key normalization is stricter than visible ID normalization,
   which can cause surprising collisions.

## Suggested implementation order

1. Add `test/` with the lowest-risk unit tests.
2. Extract `core.rb` and `linux_inotify.rb`.
3. Extract `runtime/*`.
4. Extract `commands/*` and `cli.rb`.
5. Fix the four known behavioral issues above.
6. Expand tests around the bug fixes.
7. Run full verification.

## Verification checklist

Run all of the following after the split:

```bash
ruby -c bin/harnex
ruby -c lib/harnex.rb
ruby -Itest test/**/*_test.rb
harnex send --help
harnex status --help
harnex wait --help
```

If live sessions are available, also verify:

```bash
harnex status
harnex send --id <live-id> --status
```

## Done criteria

- `lib/harnex.rb` is a loader, not the implementation dump.
- Runtime objects and command handlers live in separate files.
- Existing CLI behavior still works.
- There is a committed `minitest` suite covering the core logic.
- The known `--port` / exit-file / `wait` / ID-collision issues are either fixed
  or explicitly deferred in code comments with tests documenting current
  behavior.
