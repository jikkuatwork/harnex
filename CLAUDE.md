# Harnex — Agent Orientation

**Read `koder/STATE.md` first.** It is the thin handoff document
between agent sessions: past, present, and future only.

## Project tracking

- `koder/STATE.md` — thin handoff: recent past, current focus, next step
- `CHANGELOG.md` — durable change history
- `koder/issues/` — individual issue files (features, bugs, ideas)
- `koder/plans/` — implementation plans with phased instructions.
  Plan IDs are monotonic integers (234, 235, 236, …); never use
  `234a`/`234b` suffixes. To group related plans, use a *layer* —
  e.g. "Layer A covers plans 234, 235, 236." Document the layer in
  the plan files themselves, not in the filename.
- `koder/releases/` — per-release verification records (functional
  matrix + long-run telemetry + what was *not* covered)
- `koder/DISPATCH.jsonl` — durable, append-only log of every harnex
  dispatch run from this repo. Treat it as telemetry data, not part
  of any code change. **Never `git checkout`, `git restore`, or
  otherwise revert this file** — every row was written by a real
  session (often a peer worker running in parallel), and reverting
  destroys legitimate history that cannot be recovered. If a reviewer
  flags appended rows as "out-of-scope creep," that is incorrect:
  rows are runtime artefacts and should be committed alongside (or
  separately from) the code change, not discarded. Only edit the
  file by hand if a row is genuinely malformed.

Always check STATE.md at the start of a session to orient yourself.
If you complete work, update STATE.md before ending.

## State hygiene

`koder/STATE.md` is not a changelog, release record, architecture
inventory, or issue tracker. Keep it short enough to read at session
open:

- **Past:** the latest completed milestone and links to durable records.
- **Present:** the current focus, active blocker, and any immediate
  caveat the next agent must know.
- **Future:** the next recommended step, with links to the relevant
  issue or plan.

Do not paste full release notes, test matrices, long issue tables,
implementation transcripts, or historical project timelines into
`STATE.md`. Put durable change history in `CHANGELOG.md`, release
verification in `koder/releases/`, and issue-specific detail in
`koder/issues/` or `koder/plans/`. When closing a session, update
`STATE.md` only with the minimal handoff needed for the next session.

### Date format (STATE.md and CHANGELOG.md)

Use `YYYY-MM-DD | hh:mm AM/PM | TZ` for human-facing dated entries
in `koder/STATE.md` and `CHANGELOG.md` — e.g.
`2026-05-07 | 05:59 PM | IST`. The pipe-separated form is precise
enough to order same-day events and keeps the timezone explicit.

Forward-only: do not backfill existing entries. Other places keep
their current formats — `koder/DISPATCH.jsonl` stays ISO 8601 with
offset (machine-readable), and `koder/issues/` / `koder/plans/` /
`koder/releases/` keep date-only `YYYY-MM-DD` unless the entry
genuinely needs a timestamp.

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
lib/harnex/commands/             Command implementations (run, send, wait, stop, status, logs, pane, agents-guide)
guides/                           Agent-facing CLI guide topics
lib/harnex/runtime/              Session, state machine, inbox, API server
lib/harnex/adapters/             Adapter base + generic/codex/claude adapters
lib/harnex/watcher.rb            File watcher (auto-selects backend)
lib/harnex/watcher/inotify.rb    Linux inotify via Fiddle
lib/harnex/watcher/polling.rb    Cross-platform stat-based fallback
test/                            Minitest suite
koder/STATE.md                   Project state (read this first)
koder/issues/                    Issue tracker
koder/plans/                     Implementation plans
koder/releases/                  Release verification records
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

## Adapter transports — PTY and JSON-RPC are both first-class

Adapters interface with the wrapped CLI over **PTY**, **JSON-RPC**, or
both. Neither is a legacy fallback; they serve different needs.

- **PTY** is the broad-compatibility transport. Most CLIs only ship a
  TUI, so PTY is the default path for any new harness adapter (claude,
  opencode, aider, cursor, etc.). It is also the right choice whenever
  the user wants to *see* the TUI live in tmux.
- **JSON-RPC** is the structured transport, offered by harnesses that
  ship one (e.g. `codex app-server`). When available it gives cleaner
  state detection, structured task-complete signals, and approval
  mediation without text scraping.

Each harness adapter ideally supports both: PTY for visibility and
broad compat, JSON-RPC for autonomous dispatch when the harness
exposes it. Many harnesses have no JSON-RPC; that's fine — PTY covers
them. The PTY path is **permanent** and is not slated for removal.

The current flag `--legacy-pty` is a misnomer kept for backwards
compatibility; rename is queued for post-freeze followup.

## If you are running inside harnex

Check `$HARNEX_ID` and `$HARNEX_SESSION_CLI` to confirm. You can use
`harnex send`, `harnex status`, and `harnex wait` to coordinate with
peer sessions. See `harnex agents-guide dispatch` for full usage patterns.

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

### Worker ID naming

Use `cx-<role>-<issue-or-tag>` for `--id` / `--tmux` so peer sessions are
self-describing in `harnex status`, tmux windows, and DISPATCH rows.
Single-letter role codes:

- `i` — implement (e.g. `cx-i-35` implements issue #35)
- `r` — review (`cx-r-35` reviews the implementation)
- `p` — plan (`cx-p-35`)
- `f` — fix (`cx-f-35`)
- `t` — test (`cx-t-35`)
- `a` — audit (`cx-a-35`)
- `d` — docs (`cx-d-35`)

For non-issue work, substitute a short tag: `cx-a-jsonrpc`,
`cx-d-readme`. If parallel workers share a role on the same issue,
disambiguate with a tag suffix (`cx-i-35-tier1`, `cx-i-35-tier2`),
not a bare letter.

## Long-running work: spawn a buddy

For any unattended or long-running work (overnight, multi-hour), spawn a
**buddy** — a second harnex agent that watches the worker and nudges it if
it stalls. The buddy is an LLM, so it reasons about what's happening rather
than pattern-matching.

The invoker (you) doesn't need to be a harnex session. Spawned agents get
`$HARNEX_SPAWNER_PANE` — the stable tmux pane ID of whoever ran `harnex run`
— so the buddy can reach back to you via `tmux send-keys`.

See `recipes/03_buddy.md` for the full pattern.

## Releasing

The harnex gem and the harnex CLI on `PATH` live on the **same
machine**. Pushing the gem to RubyGems does NOT update the local
binary — that's a separate `gem install`. Skipping it leaves
`harnex *` invocations running an older version with the older
adapter behavior, which silently breaks dispatch flows. Always do
both, in order:

1. `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`
   — tests must be green at HEAD before tagging.
2. `gem build harnex.gemspec` — produces `harnex-<VERSION>.gem`.
3. `bin/gem-push harnex-<VERSION>.gem` — pushes to RubyGems. Reads
   the TOTP key from `.env` and generates the OTP automatically. Do
   NOT read `.env` yourself or generate OTP inline.
4. `git tag -a v<VERSION> -m "harnex <VERSION> — <summary>"` then
   `git push origin main && git push origin v<VERSION>`.
5. `gem install harnex` — pulls the just-published version into the
   local install. **Do not skip this.** Verify with
   `harnex --version` (must match the new VERSION).
6. Smoke-test a relevant new surface (e.g. `harnex doctor` on 0.6.0).
7. Clean up the local `.gem` artifact: `rm harnex-<VERSION>.gem`.
8. Update `koder/STATE.md` with what shipped and the unblock state.
9. Write `koder/releases/<VERSION>.md` capturing the verification
   matrix: functional tests run, long-run telemetry (DISPATCH row
   metrics, disconnections, exit reason), and an explicit *did not
   cover* section so future regressions land against a known
   baseline. See `koder/releases/0.6.5.md` for the format.

Agent guides are bundled in the gem (`s.files` glob includes
`guides/*.md`) and are available through `harnex agents-guide`.

## Development notes

- Ruby 3.x, stdlib only (no gems)
- File watching: inotify on Linux, stat-polling fallback on macOS/other
- Run tests: `ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'`
