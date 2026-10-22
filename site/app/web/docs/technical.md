# Technical Reference

For what harnex is and whether you'd want it, see
[README.md](README.md). This document covers commands, patterns,
and internals.

## Commands

### Lanes — `ask`, `delegate`, `result`, `reply`, `land`, `discard`, `lanes`

The agent-facing layer. Each verb prints plain text (the worker's reply, then
a `── NAME:` footer with state, model, cost, commits and next commands) and
shares exit codes: 0 done, 1 failed, 2 usage error, 124 still working.
Blocking verbs default to `--timeout 9m`. See [docs/lanes.md](docs/lanes.md)
and `harnex help <verb>`.

```bash
harnex ask "QUESTION" [--model M] [--write] [--fallback-model M]
harnex delegate [--worktree NAME | --name NAME] [--no-wait] [--model M] "TASK"
harnex result [NAME...]
harnex reply NAME "MESSAGE" [--model M]
harnex land [NAME...]
harnex discard NAME...
harnex lanes [--all] [--closed] [--json]
```

### `harnex mcp` — The lane verbs as MCP tools

```bash
harnex mcp install [--claude] [--pi] [--no-agent] [--dry-run]
harnex mcp status
harnex mcp uninstall
harnex mcp            # stdio server (what clients run)
```

See [docs/mcp.md](docs/mcp.md).

### `harnex run` — Start an agent

```bash
harnex run pi
harnex run pi --id pi-i-13 --tmux pi-i-13 --model openai/gpt-5.1
harnex run pi --cwd ../wt-13 --root . -- --no-approve
harnex run claude --id cl-r-13 --tmux cl-r-13
```

| Flag                | What it does                                                        |
|---------------------|---------------------------------------------------------------------|
| `--id ID`           | Name this session (default: random)                                 |
| `--description`     | Store a short session description                                   |
| `--detach`          | Run in background, no terminal                                      |
| `--tmux [NAME]`     | Run in a tmux window you can watch                                  |
| `--host HOST`       | Bind a specific API host                                            |
| `--port PORT`       | Force a specific API port                                           |
| `--watch`           | Enable blocking babysitter mode (foreground only)                   |
| `--stall-after DUR` | Idle threshold before force-resume (default: `480s`)                |
| `--max-resumes N`   | Max forced resumes before escalation (default: `1`)                 |
| `--preset NAME`     | Watch preset (`impl`, `plan`, `gate`), requires `--watch`           |
| `--watch-file PATH` | Auto-send a file-change hook (`--watch PATH`/`--watch=PATH` legacy) |
| `--context TXT`     | Give the agent a task on startup                                    |
| `--context-file PATH` | Read the startup task from a file (refuses an empty result)       |
| `--context-section TXT` | With `--context-file`, send only the section starting at TXT    |
| `--auto-stop`       | With `--context`, stop after accepted task completion               |
| `--wait-done`       | With `--tmux`/`--detach`, block and print the first turn's result   |
| `--wait-timeout DUR` | Cap `--wait-done`; on 124 the output names a `resume` command      |
| `--model NAME`      | Pi model (`provider/model`), verified over RPC before the prompt    |
| `--effort LEVEL`    | Pi thinking level, verified over RPC before the prompt              |
| `--cwd DIR`         | Run the agent from DIR (e.g. a worktree lane)                       |
| `--root DIR`        | Override root attribution without changing the child cwd            |
| `--owner-tag TAG`   | Own the dispatch as `<owner>/TAG` for `watch --owner --owner-tag`   |
| `--meta JSON`       | Attach bounded caller metadata                                      |
| `--phase TEXT`      | First-class phase attribution (optionally repo-allowlisted)          |
| `--artifact-report PATH` | Override the harness-authored v1 receipt destination            |
| `--require-artifact-report` | Compatibility strict flag; default receipt path is sufficient |
| `--timeout SEC`     | Wait budget for detached registration                               |

A Pi turn is accepted when it settles. With `--require-artifact-report` it must
also show structured command/tool activity or a Git delta, or it is rejected as
`completed_no_activity`. PTY adapters stop on prompt return. Every transport
gets a harness-authored observed-state receipt; optional worker claims never
determine acceptance, and receipt-write failure is fail-closed.

`--wait-done` prints the launch fields plus `turn_result` (`outcome_class`,
`model`, `commits`, `turn_commits`, and `final_message`, the worker's last reply)
and uses the `wait --until done` exit codes. Pass Pi startup flags after `--`;
unattended runs should choose Pi project trust with `--approve` or `--no-approve`.

### `harnex doctor` — Preflight, drift, and retention

```bash
harnex doctor
harnex doctor --sweep
harnex doctor --prune --dry-run
harnex doctor --prune
```

Output is JSON: the Pi RPC prerequisite (Pi >= 0.80.4; `--adapter pi|all`),
events/output/receipt retention status, and versioned `capabilities`. `--sweep`
adds read-only live-session/tmux drift diagnostics. `--prune --dry-run`
previews age/size-cap deletions; `--prune` applies them while preserving current
and live-session files. See [docs/configuration.md](docs/configuration.md).

### `harnex preflight` — Prove an adapter end to end

```bash
harnex preflight pi --cwd ~/repo -- --no-approve
harnex preflight pi --cwd ~/repo --commit-check --model openai/gpt-5.1 -- --no-approve
```

Spends one real model turn (two with `--commit-check`, which commits in a
throwaway scratch repo) and prints a JSON verdict: registration, boot,
permission, task read, workspace write, command exit, receipt, claims,
completion, and stop. Exits 0 only when every required check passes.

### `harnex artifact-report` — Validate receipts and legacy proof

```bash
harnex artifact-report init .harnex/reports/worker.json
harnex artifact-report validate .harnex/reports/worker.json --final
```

Normal runs write their own final receipt, so workers do not call `init`.
`validate` emits bounded machine-readable field diagnostics; `--final` accepts
a complete harness receipt whose observed terminal state was accepted. `init`
remains for legacy/manual v1 documents, whose older successful-validation
contract is still supported.

### `harnex send` — Talk to a running agent

```bash
harnex send --id worker --message "implement plan A"
```

| Flag              | What it does                           |
|-------------------|----------------------------------------|
| `--id ID`         | Which agent to talk to                 |
| `--message`       | The message text                       |
| `--wait-for-idle` | Block until agent finishes processing  |
| `--wait-done`     | Block until the turn settles; print its result |
| `--repo PATH`     | Resolve session from a repo root       |
| `--cli CLI`       | Filter by CLI type                     |
| `--submit-only`   | Just press Enter (PTY adapters only)   |
| `--no-submit`     | Type without Enter (PTY adapters only) |
| `--force`         | Send even if the agent looks busy      |
| `--no-wait`       | Don't wait for delivery confirmation   |
| `--relay`         | Force relay header formatting          |
| `--no-relay`      | Suppress automatic relay headers       |
| `--port` / `--token` | Send directly to a known API port  |
| `--timeout`       | Overall wait budget                    |

A busy Pi worker takes the message at once as a follow-up
(`delivery: "follow_up"`) and runs it when the current turn ends;
`--force` steers it into the running turn instead. Other adapters queue
it until the agent is at a prompt.

### `harnex stop` — Ask an agent to stop

```bash
harnex stop --id worker
harnex stop --id worker --timeout 5
```

Pi: aborts any running turn over RPC and terminates the
`pi --mode rpc` process. PTY adapters get their native exit
sequence (`/exit` for Claude, Ctrl+C for OpenCode). Retries
transient failures for up to the given timeout.

### `harnex status` — See running agents

```
ID       CLI     PID    PORT   AGE  IDLE  STATE   REPO   DESC
pi-i-13  pi      12345  43123  36s  12s   prompt  ~/...  -
cl-r-13  claude  12346  43124   8s  -     busy    ~/...  -
```

Text mode includes an `IDLE` column derived from `log_idle_s` (`-` means no
transcript activity yet).

Use `--json` for full payloads. JSON includes:

- `log_mtime` (ISO8601 or `null`) — transcript file mtime
- `log_idle_s` (Integer or `null`) — seconds since last transcript write
- `artifact_report_path` — harness-owned final observed-state receipt
- `artifact_claims_path` — optional bounded worker-claims input

Use `--all` for all repos.

### `harnex wait` — Wait for an agent to finish

```bash
harnex wait --id pi-i-13
harnex wait --id pi-i-13 --until done --timeout 900
harnex wait --id pi-i-13 --until done --after-seq 812 --timeout 9m
```

`--until done` is the work-level fence: 0 accepted, 1 failed, 2 completed but
proof rejected, 3 no such session, 4 stalled (`--stall-after`), 124 observer
timeout (the worker keeps running). `--after-seq` (from `harnex send` output)
waits for the turn that message started, not an earlier result.

### `harnex watch` — Monitor dispatches

```bash
harnex watch --id pi-i-13 --until done --max-wait 90m
harnex watch --owner --stall-after 25m
harnex watch --owner --once --timeout 9m --owner-tag sub-a
harnex watch --owner --until-idle --timeout 90m
```

`--id` watches one existing `--tmux`/detached session with the `wait --until
done` exit codes and optional `--done-marker` / `--fail-marker` files.
`--owner` streams one JSON line (`harnex.owner_event.v1`) per change for every
dispatch the calling Claude Code or Pi session launched; results carry
`final_message`. `--once` prints what is ready and exits (124 when nothing is
new); `--until-idle` keeps printing until no lane is running. `--owner-tag`
narrows to lanes launched with `run --owner-tag`.

### `harnex ask` — Ask a Pi worker one question

```bash
harnex ask "Which module parses the dispatch rows, and is it tested?"
harnex ask --model openai/gpt-5.1 --file /tmp/review.md --timeout 9m
```

Runs a Pi worker in a tmux window with read-only tools, prints its answer on
stdout, and stops it. `--write` allows edits and commands; `--json` prints the
full result. Exit codes: 0 answered, 1 failed, 2 proof rejected or usage
error, 124 timeout (the worker keeps running).

### `harnex history` — List completed dispatches

```bash
harnex history
harnex history --json | jq .
```

Reads the canonical v2 stream at `<git-root>/.harnex/dispatch.jsonl`; use
`--global` for `~/.local/state/harnex/dispatch.jsonl` outside a repo. Each run
has one `dispatch_start` plus one rich `dispatch_end`. That stream is the only
destination; no flag mirrors the end row into a second file.

### `harnex logs` — Read session transcripts

```bash
harnex logs --id worker --lines 50
harnex logs --id worker --follow
```

### `harnex pane` — Capture a tmux screen snapshot

```bash
harnex pane --id worker --lines 40
harnex pane --id worker --follow
harnex pane --id worker --json
```

Notes:
- Works only for tmux-backed sessions
- Resolves against the live tmux pane target, not just the harnex session ID
- If a session was started from another worktree, `pane` can fall back to a
  unique cross-repo ID match; use `--repo` when the same ID exists in more
  than one repo root

## Usage Patterns

### Atomic send+wait

Use `--wait-for-idle` instead of separate send + sleep + wait:

```bash
# Replaces: send → sleep 5 → wait --until prompt
harnex send --id pi-i-13 --message "implement the plan" --wait-for-idle --timeout 600
```

With Pi, `--wait-done` returns the result of the turn the message started.

### Agents talking to each other

When one harnex agent sends to another, the receiver sees a
relay header automatically:

```
[harnex relay from=claude id=supervisor at=2026-03-14T12:00]
implement A
```

Messages to a busy agent queue (Pi: become follow-ups) and
auto-deliver when ready.

### Background agents

**tmux** (observable):

```bash
harnex run pi --id pi-i-13 --tmux pi-i-13
```

**Headless** (no terminal):

```bash
harnex run pi --id pi-i-13 --detach
```

### Supervisor pattern

One agent manages others, one worktree lane per worker:

```bash
harnex run pi --id pi-i-1 --tmux pi-i-1 --cwd ~/wt-a --root ~/repo
harnex run pi --id pi-i-2 --tmux pi-i-2 --cwd ~/wt-b --root ~/repo

harnex send --id pi-i-1 --message "implement feature A" --wait-for-idle --timeout 600
harnex send --id pi-i-2 --message "implement feature B" --wait-for-idle --timeout 600

harnex run claude --id cl-r-1 --tmux cl-r-1
harnex send --id cl-r-1 --message "review changes" --wait-for-idle --timeout 300
```

With `--context ... --auto-stop` on each lane, a Claude Code or Pi supervisor
can collect every result with `harnex watch --owner --until-idle`.

### Context on startup

```bash
harnex run pi --id pi-i-1 --tmux pi-i-1 --cwd ~/repo/worktree --root ~/repo \
  --context "Implement the auth feature. Commit when done."

harnex run pi --id pi-i-1 --tmux pi-i-1 \
  --context-file koder/briefs/1.md --context-section "## Task" \
  --auto-stop --wait-done --wait-timeout 9m
```

### File watching

```bash
harnex run pi --id pi-i-13 --watch-file ./tmp/status.jsonl
```

Agent gets notified when the file changes. File doesn't need to
exist at startup.

Legacy compatibility: `--watch PATH` and `--watch=PATH` still configure
file-hook mode.

## harnex events

`harnex events` streams structured per-session JSONL for orchestrators and
monitoring tooling.

```bash
harnex events --id worker
harnex events --id worker --snapshot
harnex events --id worker --from 2026-04-29T10:00:00Z
harnex events --id worker | jq -c '.'
```

| Flag | What it does |
|------|---------------|
| `--id ID` | Session ID to inspect (required) |
| `--[no-]follow` | Stream appended events (default: follow) |
| `--snapshot` | Print current event file and exit (`--no-follow`) |
| `--from TS` | Replay floor (ISO-8601, inclusive; `ts >= from`) |
| `--repo PATH` | Resolve ID from a specific repo root |
| `--cli CLI` | Filter active-session resolution by CLI |

Exit codes:

- `0` — snapshot completed, or follow mode observed `type: "exited"`
- `1` — operational error (missing stream/session, invalid `--from`,
  stream truncated/disappeared, lookup failure)

Transport file (append-only JSONL):

```
~/.local/state/harnex/events/<repo_hash>--<id>.jsonl
```

Each row uses schema v1 with envelope fields `schema_version`, `seq`, `ts`,
`id`, and `type`. Lifecycle, send, usage, git, summary, attempt, completion,
and adapter-specific events are additive; consumers must ignore unknown event
types. `send.msg` is a 200-character preview with `msg_truncated` when shortened.

Schema details and compatibility guarantees are in [docs/events.md](docs/events.md).

## Architecture

```
 bin/harnex
   │
   └── lib/harnex.rb (loader)
         │
         ├── CLI          dispatch: run / send / status / wait / stop
         ├── Runner        spawn sessions (foreground/detach/tmux)
         ├── Sender        resolve target, inject text
         ├── Status        list live sessions
         ├── Waiter        block until session exits
         ├── Stopper       send stop sequence
         │
         ├── Session       PTY or Pi RPC lifecycle, HTTP server, registry
         ├── SessionState  state machine (prompt/busy/blocked)
         ├── Inbox         per-session message queue
         ├── Message       queued message struct
         │
         ├── FileChangeHook   inotify file watcher
         └── LinuxInotify     raw inotify via Fiddle

 lib/harnex/adapters.rb   registry: claude, opencode, pi; anything else → generic
 lib/harnex/adapters/
   ├── base.rb      adapter interface (PTY transport by default)
   ├── claude.rb    Claude Code PTY behavior
   ├── generic.rb   PTY fallback for any CLI
   ├── opencode.rb  OpenCode PTY behavior
   └── pi.rb        Pi JSONL RPC adapter (`pi --mode rpc`, default worker)
```

## Lanes and MCP

Lanes sit on top of sessions; they add a record, git plumbing and text output,
not a new runtime.

- **Records** (`lib/harnex/lanes.rb`) live in `STATE_DIR/lanes/<repo_key>--<name>.json`:
  kind (`ask`/`delegate`), main-checkout root, run root, cwd, worktree, branch,
  base sha, owner (`CLAUDE_CODE_SESSION_ID`/`PI_SESSION_ID`), requested model,
  Pi `agent_session_id`, accumulated cost, launch time and the last turn's result.
  States: `running` (a turn is out and uncollected), `done`, `failed`, `landed`,
  `discarded`.
- **Launching:** the verbs shell out to the low-level CLI. `delegate` runs
  `harnex run pi --id NAME --tmux NAME --cwd WORKDIR --root ROOT --auto-stop`
  with a brief file (`--context-file`); with `--wait-done` it blocks on the
  first result. `result` runs `harnex wait --until done --since LAUNCHED_AT`
  (each relaunch restarts the events-log `seq`, so `--since` keeps an earlier
  launch's result from matching) plus `--after-seq` for a follow-up sent to a
  live lane.
- **Follow-ups:** `reply` sends to a live worker (`harnex send --wait-done`);
  a finished lane is relaunched under the same id with `-- --session
  <agent_session_id>`, so Pi resumes the conversation.
- **Settling:** after a turn, the lane reads the launch's `usage` event (cost,
  `agent_session_id`) and records the result; the footer adds commits and a
  diffstat from git (`base_sha..HEAD`).
- **Worktrees:** `.harnex/worktrees/NAME` on branch `harnex/NAME`; `.harnex/`
  is added to `<git-common-dir>/info/exclude` on the first write.
  `land` merges with `git merge --no-edit`, leaves conflicts in progress, and
  removes the worktree and branch; lanes merged by hand are swept on the next
  call.
- **Progress:** the Pi activity tracker records the current tool name and the
  per-turn tool count (never arguments); `lanes` and MCP progress read them from
  the session's `GET /status`.
- **MCP** (`lib/harnex/mcp.rb`): newline-delimited JSON-RPC 2.0 over stdio.
  Each `tools/call` runs in its own thread and spawns the CLI verb in its own
  process group (a cancel kills the wait, never the worker); stdout writes are
  serialized; progress notifications go out every 15s when the call carries a
  `progressToken`.
- **Worker guard:** the Pi adapter adds `--exclude-tools mcp__harnex__…` to
  every worker (Pi >= 0.99) and `--no-mcp` when a `--tools` allowlist is set
  (Pi >= 1.0.4), so workers cannot start workers.

## Session Lifecycle

Foreground execution is the default operating mode for a human directly using
`harnex run`. For agent-to-agent delegation, a visible tmux session is the
preferred interactive mode because it keeps the peer's work observable.

Headless/background execution (`--detach`) should still be treated as opt-in.

When you run `harnex run pi --id pi-i-13`:

```
 1. Parse wrapper options, build adapter
 2. Validate the target binary before spawn (Pi: version >= 0.80.4)
 3. Spawn the agent: Pi as `pi --mode rpc` over stdio pipes;
      other CLIs under a PTY (pseudoterminal)
 4. Generate a random bearer token for API auth
 5. Pick a port:
      hash(repo_root + id) % port_span + base_port
      walk forward until a free port is found
 6. Start HTTP server on 127.0.0.1:<port>
 7. Opportunistically enforce configured age/size retention for events/output/receipts,
      preserving current and live-session files; then write registry file:
      ~/.local/state/harnex/sessions/<repo_hash>--<id>.json
      and open transcript file:
      ~/.local/state/harnex/output/<repo_hash>--<id>.log
      and open events file:
      ~/.local/state/harnex/events/<repo_hash>--<id>.jsonl
 8. Start background threads:
      - PTY reader (screen buffer) or Pi JSONL reader (RPC events)
      - State machine (adapter parses screen, or Pi events, for state)
      - Inbox delivery (queue -> inject when prompt)
      - File watcher (if --watch-file was given)
 9. PTY: relay terminal I/O between user and agent;
      Pi: send the --context prompt and print a synthesized transcript
10. On exit: clean up registry, write exit status
```

## PTY and Screen Parsing

Harnex spawns the agent inside a pseudoterminal (PTY). This
preserves the agent's full terminal UI while letting harnex:

- Read screen output into a ring buffer
- Feed the buffer to the adapter for state detection
- Inject text by writing to the PTY input

The screen text includes raw terminal escape sequences. The
adapter's `normalized_screen_text` strips ANSI and OSC codes
before parsing.

Pi does not run under a PTY: its adapter speaks JSONL over stdio
and takes state from RPC events (see the Pi adapter below).

## Adapter Contract

Each adapter in `lib/harnex/adapters/` implements:

| Method                    | Purpose                         |
|---------------------------|---------------------------------|
| `base_command`            | CLI args to launch the agent    |
| `input_state(screen)`     | Parse screen -> state hash      |
| `build_send_payload(...)` | Build injection with submit     |
| `inject_exit(writer)`     | Send adapter-specific stop text |
| `infer_repo_path(argv)`   | Extract repo path from CLI args |
| `wait_for_sendable(...)`  | Wait strategy before sending    |
| `transport`               | `:pty` (PTY) or `:stdio_jsonl_rpc` (JSONL RPC) |
| `validate_runtime!`       | Optional version gate (Pi >= 0.80.4) |

### Input States

PTY adapters read the screen and return a state hash; Pi reports
`prompt`, `busy`, or `disconnected` from RPC events:

| State                    | `input_ready` | Meaning               |
|--------------------------|---------------|-----------------------|
| `prompt`                 | `true`        | Ready for input       |
| `busy`                   | `false`       | Pi turn in progress   |
| `workspace-trust-prompt` | `false`       | Needs Enter to confirm|
| `confirmation`           | `false`       | Modal confirmation    |
| `unknown`                | `nil`         | Can't determine       |

### Pi Adapter (default — JSONL RPC)

- `transport :stdio_jsonl_rpc` launches `pi --mode rpc` and speaks Pi's
  strict LF-delimited JSONL protocol. It is not JSON-RPC 2.0.
- Requires Pi >= 0.80.4 and fails before spawn when the installed version
  cannot provide the final `agent_settled` fence. Verify with
  `harnex doctor --adapter pi`.
- `agent_end` remains busy because retry, compaction recovery, or a queued
  continuation may follow. `agent_settled` inspects the authoritative final
  assistant `stopReason`: `stop` completes; `error`, `aborted`, `length`, a
  missing reason, or an unknown reason fails closed.
- Pi >= 0.84 emits delta-only `message_update` events. Harnex correlates those
  deltas with `message_start` / `message_end` and does not depend on the removed
  cumulative message snapshot.
- Harnex `--model` and `--effort` become Pi `--model` / `--thinking`
  startup flags and are verified with `get_state`; a model mismatch or clamped
  effort is rejected before prompting without persisting an RPC model switch
  into Pi's user defaults.
- Busy sends become Pi follow-ups (`streamingBehavior=followUp`), delivered
  when the current turn ends; forced busy sends use `streamingBehavior=steer`.
- `task_complete` carries `final_message` (the last assistant reply, up to
  4,000 characters, full text at `final_message_path`).
- `--tmux` shows Harnex's synthesized RPC transcript, not Pi's native TUI.
- RPC requests have a 30-second response bound. Stderr is continuously drained
  into a bounded diagnostic tail, and subprocess status comes from Open3's wait
  thread instead of racing it with another `waitpid`.
- See `docs/pi-rpc.md` for trust policy, telemetry, and compatibility details.

### Claude Adapter

- Detects workspace trust prompt ("Quick safety check")
- Allows `--submit-only` to clear the trust prompt
- Detects prompt via `--INSERT--` marker or `›` prefix
- Multi-step submit: types text, then sends Enter after a
  short delay so pasted prompts are actually submitted

### OpenCode Adapter

- Uses optimistic PTY prompt detection to avoid inbox deadlock
  when OpenCode's alternate-screen TUI omits stable plain-text
  prompt markers in snapshots.
- Stop sequence sends a double Ctrl+C to match OpenCode's native
  terminal shutdown path (interrupt first, force-quit second if
  needed).
- Multi-step submit mirrors Claude's PTY behavior: text first,
  then Enter with a short delay.

## State Machine

`SessionState` tracks the agent's readiness:

```
                  ┌──────────┐
       ┌─────────│  unknown  │──────────┐
       │         └──────────┘           │
       ▼                                ▼
 ┌──────────┐    screen change    ┌──────────┐
 │  prompt   │ <───────────────── │   busy   │
 │           │ ────────────────>  │          │
 └──────────┘    screen change    └──────────┘
       │                                │
       ▼                                ▼
 ┌──────────┐                    ┌──────────┐
 │ blocked  │                    │ blocked  │
 └──────────┘                    └──────────┘
```

- Uses a Mutex + ConditionVariable for thread-safe access
- `wait_for_prompt(timeout)` blocks until state == `:prompt`
- State is updated by the PTY reader thread calling the
  adapter's `input_state` on each screen change; for Pi, by
  RPC lifecycle events (`agent_start` busy, `agent_settled` prompt)

## Inbox and Message Queue

Each session has an `Inbox` with a background delivery thread:

```
 harnex send ──> POST /send ──> Inbox#enqueue
                                  │
                    ┌─────────────┴──────────────┐
                    │                             │
              prompt + empty queue?          otherwise
                    │                             │
              deliver_now()              push to @queue
              return 200                 return 202
                                              │
                                    delivery_loop thread
                                    wait_for_prompt()
                                    deliver_now()
```

### Message Lifecycle

| Status      | Meaning                              |
|-------------|--------------------------------------|
| `queued`    | In the queue, waiting for delivery   |
| `delivered` | Injected into agent's terminal       |
| `failed`    | Injection raised an error            |

Poll status with `GET /messages/:id`.

A send to a busy Pi worker skips the queue: it is handed to Pi at once
as a follow-up (`delivery: "follow_up"`), so it cannot expire.

## HTTP API

All endpoints are on `127.0.0.1:<port>`. Every request needs
the bearer token from the registry file.

### `GET /status`

Returns JSON:

```json
{
  "ok": true,
  "session_id": "abc123",
  "repo_root": "/path/to/repo",
  "cli": "pi",
  "id": "pi-i-13",
  "description": "implement auth module",
  "pid": 12345,
  "host": "127.0.0.1",
  "port": 43123,
  "command": ["pi", "--mode", "rpc"],
  "started_at": "2026-03-13T20:45:00Z",
  "last_injected_at": null,
  "injected_count": 0,
  "input_state": {
    "state": "prompt",
    "input_ready": true
  },
  "agent_state": "prompt",
  "inbox": {
    "pending": 0,
    "delivered_total": 3
  }
}
```

### `POST /send`

Send JSON body:

```json
{
  "text": "implement plan A",
  "submit": true,
  "enter_only": false,
  "force": false
}
```

- **200** with `"status": "delivered"` — sent immediately
- **202** with `"status": "queued"` and `message_id` — agent
  is busy, message will auto-deliver
- **400** — missing text or bad request
- **409** — agent not ready (use `--force` to override)
- **503** — inbox is full

### `POST /stop`

Tells the session adapter to inject its stop sequence.
The `harnex stop` CLI retries transient API failures for up
to its `--timeout` budget before returning exit code 124.

### `GET /messages/:id`

Check delivery status of a queued message.

### `GET /health`

Alias for `/status`.

## Session Registry

Registry files at `~/.local/state/harnex/sessions/`:

```
<repo_hash>--<normalized_id>.json
```

The repo hash is a hex digest of the git root path. The ID is
normalized: lowercased, non-alphanumeric chars replaced with
dashes, leading/trailing dashes stripped.

Contents: port, PID, token, CLI, repo root, timestamps,
injection counters, agent state, inbox stats.

Cleaned up on normal exit. Stale files (dead PID) are ignored
during lookups.

## Exit Status

When a session exits, harnex writes:

```
~/.local/state/harnex/exits/<repo_hash>--<normalized_id>.json
```

This lets `harnex wait` return exit info even if the session
registry entry is already gone.

## Output Transcript

Every session also writes a repo-keyed transcript:

```
~/.local/state/harnex/output/<repo_hash>--<normalized_id>.log
```

- PTY output is appended as bytes are read; Pi sessions append
  the synthesized RPC transcript
- The transcript is opened in append mode, so reusing an ID
  does not wipe prior output
- `output_log_path` is exposed via `status --json` and
  detached `run` responses
- The transcript is the source of truth for the planned
  `harnex logs` operator interface

## Relay Headers

When `harnex send` detects it is running inside a harnex
session (via `HARNEX_SESSION_ID` env) and the target is a
different session, it prepends:

```
[harnex relay from=<cli> id=<sender_id> at=<timestamp>]
```

Control with `--relay` (force) or `--no-relay` (suppress).

Already-wrapped messages (starting with `[harnex relay`) are
not double-wrapped.

## File Watching

`--watch PATH` creates a `FileChangeHook` using Linux inotify
(via Fiddle, no gem needed).

- Watches the file's parent directory for write/create events
- 1 second debounce: waits for quiet time before triggering
- Injects `file-change-hook: read <path>` when triggered
- Creates the parent directory if needed
- File does not need to exist at startup

## Port Selection

Ports are deterministic to keep things predictable:

```
hash = Digest::SHA256.hexdigest(repo_root + id)
start = (hash[0..7].to_i(16) % port_span) + base_port
```

Then walks forward from `start` until a free port is found.

Defaults: base `43000`, span `4000` (range 43000–46999).

## Concurrency

Harnex uses Ruby threads, not processes:

- **PTY reader** — reads agent output into screen buffer
  (Pi: **JSONL reader** for RPC events, plus a stderr drain)
- **State poller** — feeds screen to adapter for state
- **Inbox delivery** — dequeues messages when prompt detected
- **HTTP server** — one thread per connection
- **File watcher** — inotify read loop (if enabled)

All shared state is protected by `Mutex`. The `SessionState`
and `Inbox` classes use `ConditionVariable` for signaling.

## Agent Guides

Harnex ships agent-facing guidance as Markdown files packaged inside the gem:

```
guides/01_dispatch.md
guides/02_chain.md
guides/03_buddy.md
guides/04_monitoring.md
guides/05_naming.md
guides/06_claude.md
```

The files are exposed through the CLI:

```bash
harnex agents-guide
harnex agents-guide dispatch
harnex agents-guide monitoring
harnex agents-guide claude
```

### What's in the guides

The agent guides cover:

- Detecting harnex session context through environment variables
- Defining return channels before delegation
- Short prompts that reference task files
- Relay header behavior for harnex-to-harnex messages
- Fire and Watch dispatch lifecycle
- Chain implementation phase gates
- Buddy monitoring for unattended work
- Completion signals, event/log/pane monitoring, and wall-clock caps
- Session ID, task file, and done marker naming conventions
- Claude Code sessions and subagents using Pi workers as tools

Older releases shipped `harnex skills install`; that installer was removed in
0.6.1. Agents now discover harnex directly with `harnex --help` and
`harnex agents-guide`.

## Known Limitations

- PTY prompt detection is heuristic-based. It works well
  but can misread unusual screen output. Pi state comes from
  RPC events, not the screen.
- No read-only HTTP output endpoint for local dashboards (use
  `harnex pane --follow` or `harnex logs --follow` instead).
- File watching: inotify on Linux, stat-polling fallback on
  macOS/other (works everywhere, inotify is just faster).
- The HTTP server is a simple socket server, not a full
  framework. One thread per connection, no keep-alive.

## Dependencies

- Ruby 3.x standard library only
- No gems required
- Uses: `io/console`, `pty`, `open3`, `socket`, `json`, `net/http`,
  `digest`, `fileutils`, `shellwords`, `fiddle` (for inotify)
