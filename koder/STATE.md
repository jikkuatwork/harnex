# Harnex State

Updated: 2026-03-15

## Current snapshot

- `lib/harnex.rb` is a 19-line loader.
- Code is split into separate files:
  - `lib/harnex/core.rb` — constants, env helpers, registry, port allocation
  - `lib/harnex/watcher.rb` + `watcher/{inotify,polling}.rb` — file watching (inotify on Linux, polling fallback on macOS/other)
  - `lib/harnex/adapters.rb` + `adapters/{base,generic,codex,claude}.rb`
  - `lib/harnex/runtime/{session_state,message,inbox,session,file_change_hook,api_server}.rb`
  - `lib/harnex/commands/{run,send,wait,stop,status}.rb`
  - `lib/harnex/cli.rb`
- Test suite: `test/` with 121 minitest tests, all passing.
- CLI entrypoint is `bin/harnex` (unchanged).
- Command/API redesign is implemented: generic adapter fallback, binary
  validation, random session IDs, `--description`, `stop`, `status --json`,
  and the renamed `send` flags are all live.
- Issue docs `01`, `02`, `03`, and `05` now match the implemented command and
  status surface.
- Output streaming phase 1 is in place: every session now writes a repo-keyed
  transcript file at `~/.local/state/harnex/output/<repo>--<id>.log`, exposed
  as `output_log_path` in status payloads and detached `run` responses.
- Exit status records now preserve signal metadata as `signal` alongside the
  synthesized numeric `exit_code` for signaled sessions, with regression tests
  covering zero-exit and signaled-exit persistence.
- Review follow-up fixes are in: `harnex send --timeout` now uses one shared
  deadline across lookup/request/delivery; `harnex run` rejects accidental
  single-dash flag tokens as wrapper option values; `harnex stop` retries
  transient API failures with a configurable timeout; transcript logs append
  instead of truncating on session reuse; and the Claude adapter now sends
  submit as a delayed second injection step so pasted prompts are actually
  executed.
- Agent-facing collaboration docs now prefer visible tmux-backed peer sessions
  by default, instead of hidden foreground PTYs, unless the user asks for
  headless/background behavior.
- Agent-facing docs now require an explicit return channel for delegated
  harnex work; preferred pattern is peer replies via `harnex send --id $HARNEX_ID`.
- File watching is now cross-platform: inotify on Linux, stat-polling fallback
  on macOS and other platforms. Zero external dependencies maintained.

## What harnex does

Harnex is a local PTY harness for interactive terminal agents.

- `harnex run` launches a wrapped agent session under a PTY, starts a
  localhost control API, and writes repo-scoped session metadata to the
  local registry.
- `harnex send` resolves a target session, applies relay headers when one
  harnex-managed session talks to another, and sends input through the
  local API.
- `harnex stop` sends the adapter-appropriate stop sequence to a session.
- `harnex status` reads the registry and live status endpoints, with table
  or JSON output.
- `harnex wait` blocks until a session exits or reaches a target state
  (`--until prompt`).
- Adapter logic owns CLI-specific launch args, prompt detection, submit
  behavior, stop sequence, and send-readiness waiting.
- Session output is mirrored to the terminal, stored in a 64KB ring buffer for
  prompt detection, and appended to a repo-keyed transcript file for later
  access.

## Issues

| # | Title | Status | Priority |
|---|-------|--------|----------|
| 01 | Clean stop primitive | **fixed** | P1 |
| 02 | Wait-until-prompt mode | **fixed** | P1 |
| 03 | API & command design audit | **fixed** | P1 |
| 04 | Output streaming | open | P2 |
| 05 | Inbox fast-path deadlock | **fixed** | P1 |
| 06 | Full adapter abstraction | open | P2 |
| 07 | `stop` types exit but doesn't submit | open | P1 |
| 08 | Send to fresh Codex times out | open | P2 |
| 09 | Claude vim mode not detected | open | P2 |
| 10 | Inbox management (list/drop/TTL) | open | P2 |
| 11 | Tmux pane capture | open | P3 |

See `koder/issues/` for details.

## Plans

| # | Title | Status |
|---|-------|--------|
| 01 | Monolith refactor | **done** (phases 1-2) |
| 02 | Command & API redesign | **done** |
| 03 | Output streaming | **in progress** (phase 1 done) |

See `koder/plans/` for details.

## Next step

**Fix issue 07 (`harnex stop` not submitting):** this is the highest-priority
open bug. The exit sequence is injected but the Enter keypress doesn't land,
leaving sessions hanging after `harnex stop`. Likely needs a delay between
text and newline in `inject_exit`, similar to the 75ms pattern in
`build_send_payload`.

## Confirmed bugs from earlier review (all fixed)

1. ~~`harnex send --port` broken for auth~~ -> added `--token` flag
2. ~~Exit status files keyed only by `id`~~ -> `repo_key--id_key.json`
3. ~~`harnex wait` depends on live registry~~ -> falls back to exit file
4. ~~Registry ID normalization collision~~ -> `id_key` for matching
