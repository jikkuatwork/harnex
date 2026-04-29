# Plan 24: `harnex run --watch` Blocking Babysitter (Layer 2 of #22)

Issue: #22 (Layer 2)
Date: 2026-04-29
Status: plan-write

## Goal

Add a foreground watch loop to `harnex run` that monitors live session status
(`agent_state` + Layer-1 `log_idle_s`) and performs bounded force-resume nudges
when output stalls.

This layer must make one command sufficient for delegated monitoring:

- `harnex run codex --watch --stall-after 8m --max-resumes 1`

The watcher exits on either:

- observed session exit (success path), or
- resume-cap escalation (watcher stops; session keeps running).

No presets (`--preset`), events stream (`harnex events`), or disconnect-regex
detection in this layer.

## Layer Boundary and Prerequisites

Layer-1 is a hard prerequisite and already assumed:

- `harnex status --json` includes `log_idle_s` in each session payload.

Layer-2 uses that field directly; it does not implement mtime tracking itself.

If `log_idle_s` is absent in runtime status (mismatched binary/version), watcher
fails fast with a watcher error and guidance to upgrade to Layer-1+ build.

## Recommendation: New `commands/watch.rb` Helper (Invoked by `run`)

Recommend adding `lib/harnex/commands/watch.rb` as a helper class (not a new
top-level CLI command), then invoke it from `Runner#run` only when watch mode is
enabled. This keeps `run.rb` focused on spawn/mode parsing and isolates the
polling state machine (status polling, transition logging, resume cap tracking,
exit semantics) into a testable unit with injected clock/sleep dependencies.
Extending `run.rb` inline would entangle unrelated responsibilities and make the
loop harder to unit-test without brittle end-to-end stubs.

## Flag and Parsing Design

### New watch-control flags on `harnex run`

- `--watch` (boolean): enable blocking babysitter loop after spawn
- `--stall-after <duration>`: idle threshold before forcing resume
- `--max-resumes <n>`: max forced resumes before escalation detach

### Existing `--watch PATH` conflict and compatibility

`run` already uses `--watch PATH` for file-change hook configuration. Layer-2
needs `--watch` boolean. To avoid a breaking collision:

- Add `--watch-file PATH` as the canonical file-hook flag.
- Keep legacy `--watch PATH` parsing for backward compatibility.
- Treat bare `--watch` (no value) as babysitter enable.
- Keep `--watch=PATH` meaning file-hook path (legacy form).

Compatibility rule allows this layer to ship without breaking existing file-hook
users while unlocking the new foreground watcher UX.

### Defaults

- `watch_enabled`: false
- `stall_after_s`: 480 seconds (8 minutes; conservative impl-safe default)
- `max_resumes`: 1
- `poll_interval_s`: 60 seconds (constant in watcher class)

No `--watch-interval` in Layer-2; defer unless real usage proves needed.

## Duration Parsing

No reusable duration parser exists in the current command surface.

Add a shared parser in `lib/harnex/core.rb`:

- `Harnex.parse_duration_seconds(value, option_name:)`

Accepted forms:

- plain numeric seconds: `30`, `30.5`
- suffix shorthand: `30s`, `5m`, `2h`

Rejected:

- zero/negative values
- unknown suffixes
- blank values

`--stall-after` uses this parser; parse errors raise `OptionParser::InvalidArgument`
with `--stall-after` in the message.

## Watch Loop Behavior (Foreground)

After session spawn in foreground `run` mode:

1. Print one startup line with id + effective thresholds.
2. Poll every 60s:
   - read live status for this session id
   - extract `agent_state` and `log_idle_s`
3. If state is exited/unreachable as exited:
   - print exit summary
   - return watcher success (exit code 0)
4. If `log_idle_s >= stall_after_s` and resumes used < cap:
   - send `harnex send --id <id> --force --message "resume"`
   - increment resume counter
   - print transition line (`resume X/Y`)
5. If cap reached and still stalled:
   - print `max resumes reached, escalating`
   - stop watcher loop
   - do not stop/kill target session

## Foreground UX Policy

To keep noise low, print on transitions only:

- watcher start configuration
- each forced resume action
- state transition into exited
- cap escalation terminal event

Do not print per-cycle heartbeat lines by default.

Exit summary includes:

- session id
- total polls
- resumes sent
- final observed state
- watcher outcome (`exited` vs `escalated`)

## Exit Code Policy

- `0`: session exited while under watch (regardless of session exit code)
- `2`: watcher escalated due to max resumes reached (session left running)
- `1`: watcher operational/config errors (status schema missing, HTTP errors
  that exceed retry policy, invalid arguments)

Justification: non-zero codes represent watcher outcomes/errors only; target
session non-zero exit must not be re-labeled as watcher failure.

## Implementation Steps

1. Add watch option fields to `Runner` defaults and usage text:
   - `watch_enabled`, `stall_after_s`, `max_resumes`
   - include `--watch-file` compatibility note in help
2. Extend `Runner#extract_wrapper_options` to parse:
   - bare `--watch` as babysitter enable
   - legacy `--watch PATH` / `--watch=PATH` as file-hook path
   - `--watch-file PATH` as canonical file-hook path
   - `--stall-after`, `--max-resumes`
3. Add shared duration parser in `Harnex` core and wire it into `--stall-after`.
4. Add `lib/harnex/commands/watch.rb`:
   - watch loop class (poll/status/resume/escalate)
   - constants for cadence/defaults
   - injectable `sleep` and monotonic clock hooks for tests
5. Invoke watcher from `Runner#run_foreground` after session starts.
6. Keep detached/tmux modes unchanged in Layer-2 (watcher is foreground-only).
7. Add/extend tests for parser compatibility + watch loop outcomes.

## Tests (Layer-2 Minimum Set)

### 1) Happy path: exits without resume

- status sequence: busy -> busy -> exited
- `log_idle_s` remains below threshold
- assert no send call
- assert watcher exits `0` with exited summary

### 2) Stall -> resume -> exit

- status sequence crosses `stall_after_s`
- assert one forced `resume` send with `--force`
- subsequent status reaches exited
- assert watcher exits `0`, summary includes `resumes=1`

### 3) Cap reached escalation

- status remains alive and idle above threshold
- watcher sends until `max_resumes`
- next stalled cycle triggers escalation message
- assert watcher exits `2`
- assert no stop/kill behavior invoked

### Suggested test harness pattern

Use command-unit tests with method stubs (current repo pattern) plus injected
clock/sleep lambdas inside watcher class, similar to existing constant-overrides
used in `send_test.rb`; avoid real 60s sleeps.

## Exact Files to Touch (Estimated)

- `lib/harnex/commands/run.rb` (~45 LoC)
  - new watch options + parser/disambiguation + foreground handoff
- `lib/harnex/commands/watch.rb` (new, ~95 LoC)
  - watcher loop, status/read helpers, resume dispatch, transition output
- `lib/harnex/core.rb` (~25 LoC)
  - `parse_duration_seconds` helper
- `test/harnex/commands/run_test.rb` (~40 LoC)
  - parse compatibility (`--watch`, `--watch-file`, legacy forms)
- `test/harnex/commands/watch_test.rb` (new, ~170 LoC)
  - 3 core lifecycle cases + argument/schema failures

Total expected delta: ~375 LoC including tests.

## Verification

- `ruby -Ilib -Itest test/harnex/commands/run_test.rb`
- `ruby -Ilib -Itest test/harnex/commands/watch_test.rb`
- `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`

Manual smoke:

- `harnex run codex --watch --stall-after 8m --max-resumes 1`
- `harnex run codex --watch-file NOTES.md` (legacy file-hook behavior path)

## Acceptance Checklist (Layer 2)

- [ ] `harnex run` accepts `--watch`, `--stall-after`, and `--max-resumes`
- [ ] Existing file-hook usage remains available (`--watch PATH` legacy and
      canonical `--watch-file PATH`)
- [ ] Watch loop polls every 60s and uses `log_idle_s` + live state
- [ ] Watcher sends forced `resume` nudges up to cap
- [ ] On cap reached, watcher prints escalation and exits without killing session
- [ ] Exit codes follow watcher-only semantics (0 success, non-zero watcher outcomes)
- [ ] Tests cover happy path, stall-resume-exit, and cap escalation
- [ ] No Layer-3/4/5 scope leakage (no presets/events/disconnect regex)

## Open Questions

- None blocking for Layer-2 planning. Defaults above are sufficient to proceed.
