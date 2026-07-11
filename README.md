# Harnex

Run multiple AI coding agents from your terminal and coordinate them.

Harnex wraps Claude Code, OpenAI Codex, Pi, OpenCode, or any terminal CLI in a
local harness so you can launch agents, send them tasks, inspect panes,
transcripts, and events, and stop them cleanly -- all from the command line.

```bash
gem install harnex
```

Harnex itself requires **Ruby 3.x** and uses only the Ruby standard
library. Install the CLIs you want to wrap separately; Codex JSON-RPC
support requires Codex CLI **0.128.0 or newer**, and tmux-backed
workflows require `tmux`.

Then ask the CLI what to do next:

```bash
harnex
harnex --help
harnex agents-guide
```

If you use Codex, run `harnex doctor` after installing or upgrading the
Codex CLI. It verifies the local `codex app-server` prerequisite.

`harnex agents-guide` is the agent-facing reference for dispatch, chain,
buddy, monitoring, and naming patterns. It is packaged in the gem; no skills
or project-local docs are required.

## What it does

```bash
# Start a visible one-shot worker, give it a task, and stop on completion
harnex run pi --id planner --tmux planner \
  --context "Write a plan to /tmp/plan.md" --auto-stop

# Wait for the work-level completion signal and terminal telemetry
harnex wait --id planner --until done --timeout 900

# Inspect the final state or the recent dispatch history
harnex status --id planner --json
harnex history --limit 5
```

For a long-lived interactive session, keep the worker open and send work to it:

```bash
harnex run pi --id planner --tmux planner
harnex send --id planner --message "Write a plan to /tmp/plan.md" --wait-for-idle
harnex pane --id planner --lines 30
harnex stop --id planner
```

That's the core loop. Start a fresh agent for each step, hand it one
job, watch it work, stop it when done.

### Run from a temporary/public bundle

Use `--cwd DIR` when the worker should see a specific directory rather than
the orchestrator's current repo. Harnex starts the wrapped agent in `DIR`, sets
that directory as the session root, and resolves default telemetry such as
`.harnex/dispatch.jsonl` there:

```bash
harnex run codex --cwd /tmp/leximaze_eval_run_001 \
  --id lm-run-001 \
  --context "Read README.md and write RESPONSES.jsonl and OUTPUT.md" \
  --auto-stop
```

Use `--root DIR` only when you need to override harnex's root attribution
without changing the child process cwd. `--cwd` is not a security sandbox; it is
an explicit working-directory/root selector for automation.

## Why use this

- **You want agents to plan, implement, review, and fix — in sequence.**
  Pi writes code. Claude reviews it. Pi (or another adapter) fixes the review
  findings. Each step is a fresh agent with clean context.

- **You want to see what agents are doing.** `harnex pane` captures a
  tmux-backed terminal, `harnex logs` tails the persisted transcript, and
  `harnex events` streams structured JSONL lifecycle events.

- **You don't want to babysit.** Use `--context --auto-stop` for
  one-shot work, `harnex watch` for existing visible/detached dispatches,
  `run --watch` for bounded foreground stall recovery, or `--wait-for-idle`
  as a send fence.

- **You want local-only orchestration.** Everything runs on your
  machine. No cloud services, no API keys beyond what the agents need.

## When you wouldn't use this

- You only use one agent at a time (just run it directly)
- You need cloud-hosted orchestration
- Your agents aren't terminal-based

## Supported agents

| Agent | Support |
|-------|---------|
| Claude Code | PTY adapter with prompt detection, stop sequence, workspace trust, and vim mode handling |
| OpenAI Codex | JSON-RPC `codex app-server` adapter by default; PTY mode remains supported for TUI/interactive use via `--legacy-pty` |
| Pi | JSONL RPC adapter (`pi --mode rpc`) with structured completion, tool events, extension-UI auto-cancel, and session stats telemetry |
| OpenCode | PTY adapter with native Ctrl+C stop handling and OpenCode-specific prompt/readiness heuristics |
| Any terminal CLI | Generic PTY wrapping with local API, logs, status, and best-effort prompt detection |

`harnex run codex` uses JSON-RPC by default. That path provides
structured task-completion events, approval mediation, and token usage
capture. Default JSON-RPC Codex does not accept `-m` / `--model`; pass
model settings as child CLI config, for example `harnex run codex -- -c model=NAME`.
Harnex forces Codex app-server `service_tier="flex"` unless you opt into
`service_tier="fast"` with `harnex run codex --fast`.
Use `harnex run codex --legacy-pty` when you specifically want Codex's
terminal UI or PTY-only Codex flags. The flag name is historical; the PTY path
is still supported.

`harnex run pi` launches `pi --mode rpc` and sends `--context` as a structured
`prompt` command (not a CLI positional argument). Pass Pi child flags after the
separator, for example:
`harnex run pi --context "Implement X" -- --model anthropic/claude-sonnet-4-5 --thinking high`.

## Multi-agent workflows

The real power is chaining agents together:

```bash
# 1. Pi writes a plan
harnex run pi --id pi-plan --tmux pi-plan
harnex send --id pi-plan --message "Plan the auth module, write to /tmp/plan.md" --wait-for-idle
harnex stop --id pi-plan

# 2. Fresh Pi implements the plan
harnex run pi --id pi-impl --tmux pi-impl
harnex send --id pi-impl --message "Implement /tmp/plan.md, run tests" --wait-for-idle
harnex stop --id pi-impl

# 3. Claude reviews the implementation
harnex run claude --id cl-review --tmux cl-review
harnex send --id cl-review --message "Review changes against /tmp/plan.md, write /tmp/review.md" --wait-for-idle
harnex stop --id cl-review
```

For delegated work, pass the same value to `--id` and `--tmux` so
`harnex status`, `harnex pane`, logs, and the tmux window name all line up.

Harnex ships CLI-readable agent guides for this pattern:

- **[Dispatch](guides/01_dispatch.md)** — the fire-and-watch pattern:
  spawn an agent, poll its screen, stop it when done
- **[Chain](guides/02_chain.md)** — end-to-end issue-to-code
  workflow: plan, review plan, implement, review code, fix
- **[Buddy](guides/03_buddy.md)** — spawn an accountability partner
  for long-running or overnight work
- **[Monitoring](guides/04_monitoring.md)** — completion signals and
  poll/watch patterns
- **[Naming](guides/05_naming.md)** — session IDs, task files, done markers

Read them from the installed CLI:

```bash
harnex agents-guide dispatch
harnex agents-guide monitoring
```

## Built-in dispatch monitoring

For unattended visible/background dispatches, use `harnex watch` instead of
writing a bash poll loop around `harnex wait`:

```bash
harnex run pi --id pi-impl-42 --tmux pi-impl-42 \
  --context "Implement koder/plans/42_plan.md. Run tests and commit when done."
harnex watch --id pi-impl-42 --until done --max-wait 90m \
  --done-marker /tmp/pi-impl-42-done.json \
  --fail-marker /tmp/pi-impl-42-failed.json
```

`harnex watch --until done` is the safe work-terminal watcher for existing
`--tmux` or detached sessions. It exits `0` for `task_complete`/done, non-zero
for `task_failed` or failed terminal summaries, and `124` for `--max-wait`
timeouts. It does not keep pane/status polling after a terminal failure signal.

`harnex run --watch` is a separate foreground babysitter that checks session
activity every 60s, force-resumes on stall up to a cap, and exits when the
target session exits or the resume cap is reached. It is foreground-only; use
`--tmux` or `--detach` for visible/background sessions, and `run --watch` when
the current command should launch and monitor one worker.

Presets map to stall policy defaults:

- `impl` -> `--stall-after 8m --max-resumes 1`
- `plan` -> `--stall-after 3m --max-resumes 2`
- `gate` -> `--stall-after 15m --max-resumes 0`

Explicit `--stall-after` and `--max-resumes` flags override preset defaults.

For file-change hooks, use `--watch-file PATH`. The older
`--watch PATH`/`--watch=PATH` form is still accepted for compatibility, while
bare `--watch` means babysitter mode.

For one-shot startup prompts, add `--auto-stop`. It requires `--context`
and stops the session after the first task completion or PTY prompt return.

## Completion and waiting

Choose the wait/watch predicate that matches how you launched the worker:

- `harnex watch --id ID --until done --max-wait DUR` is the safest unattended
  monitor for an existing visible or detached dispatch. It wraps the work-level
  fence, preserves the timeout/failure distinction, and can write done/fail
  marker files for legacy queue integrations.
- `harnex wait --id ID --until done --timeout SECS` is the primitive work fence.
  It returns when Harnex sees `task_complete`, `task_failed`, or a terminal
  exit, whichever comes first; failed work returns non-zero.
- `harnex wait --id ID` waits for the wrapped process to exit. This is right
  for already-exited sessions and terminal-summary recovery, but interactive
  agents can stay open after finishing a turn.
- For structured Pi RPC and Codex app-server sessions, use
  `harnex wait --id ID --until task_complete --timeout SECS` when you need the
  exact successful-turn event instead of terminal-exit fallback. Use
  `--until task_failed` to wait specifically for a failed structured turn.
- `harnex send --wait-for-idle` is an atomic send fence for PTY-style
  interactions. It proves the turn returned to an idle/prompt state, not that
  your acceptance criteria passed.
- `harnex status --id ID --json` can report `running`, `completed`, `failed`,
  or `unknown` from durable terminal summary rows even after the live registry
  is gone. Treat `state` as process/session state; use `done` and `work_state`
  as the work-level monitor contract.

Always set a timeout for unattended waits and verify the expected artifact,
tests, or git state after harnex reports completion.

For structured subscriptions, stream JSONL events:

```bash
harnex events --id pi-impl-42
```

Schema details and compatibility policy are documented in
[docs/events.md](docs/events.md).

## Dispatch history

Every finished `harnex run` writes dispatch records. By default, the terminal
summary JSONL path is `<session-root>/.harnex/dispatch.jsonl`; `--cwd DIR` makes
`DIR` the session root, including for non-git temporary bundles. The compact
history record is repo-local in a git tree and falls back to
`~/.local/state/harnex/dispatch.jsonl` outside git.
`harnex history` reads the compact records from that location, and
`harnex status --id ID --json` / `harnex wait` can use the same durable
terminal summaries when the live session registry is already gone.

Use `harnex history` to inspect it:

```bash
harnex history
harnex history --json | jq .
```

Dispatch briefs can declare soft budget metadata through `--meta`:

```bash
harnex run pi --meta '{"read_budget_lines":2000,"output_ceiling_lines":800}' ...
```

Workers can also write a small machine-readable proof sidecar while keeping the
canonical explanation in plain-text `koder/` files:

```bash
harnex run pi --id pi-i-52 \
  --artifact-report .harnex/reports/pi-i-52.json \
  --context 'Run validation, update koder/issues/52.md, and write JSON proof to $HARNEX_ARTIFACT_REPORT_PATH' \
  --auto-stop
```

The sidecar schema is `harnex.artifact_report.v1`; harnex exposes the path as
`HARNEX_ARTIFACT_REPORT_PATH` / `HARNEX_VALIDATION_REPORT_PATH`, then records a
compact `artifact_report`, `validation`, and `artifacts` summary in the dispatch
row. A sidecar can also assert the bounded outcome (`accepted`, `rejected`,
`no_change`, or `unknown`); git changes alone never imply semantic acceptance.
Missing or malformed reports are warning telemetry, not wrapped-process crashes.

Queue runners can pass first-class attribution without hiding it in prose:

```bash
harnex run pi --project-id harnex --queue-id queue-005 --entry-id SP-4 \
  --phase implement --intent queue-work --require-attribution ...
```

Soft budget metadata is copied into summary `meta`; queue/agent/reliability
metadata is copied into top-level `queue`, `agent`, and `reliability` summary
blocks. Every terminal row also has `usage` (so null is distinguishable from
explicit zero or an estimate), `attribution`, `outcome`, and a joinable
per-session `attempt` block. Terminal summary `actual` records timing, exit
classification, token usage when the adapter can capture it, adapter-reported
`cost_usd` when reliably available, git deltas, task-completion state,
operational counters (`stalls`, `force_resumes`, `disconnections`,
`tool_calls`, `commands_executed`), output/event log paths, and rough volume
measurements such as `lines_changed`, `output_lines`, `output_bytes`, and
`event_records`.
Harnex records the data only; consumers decide whether to fail closed. See
[docs/dispatch-telemetry.md](docs/dispatch-telemetry.md) for the field
contract.

## Long-running and overnight work

For plain "force-resume on stall" recovery, use
`harnex run pi --watch --preset impl --context "Read /tmp/task.md"`.

A **buddy** is for richer reasoning: doc drift checks, semantic sanity checks,
and multi-session correlation. It's still just another harnex session.

### Example: keep a worker from stalling

Spawn a buddy alongside a long-running implementation worker:

```bash
harnex run pi --id worker-42 --tmux worker-42
harnex run pi --id buddy-42 --tmux buddy-42
harnex send --id buddy-42 --message "$(cat <<'EOF'
Watch harnex session worker-42.
Every 5 minutes: run `harnex pane --id worker-42 --lines 30`.
If it looks stuck at a prompt with no progress for 10+ minutes,
nudge it: `harnex send --id worker-42 --message "Continue your task."`.
When it exits, report back:
  tmux send-keys -t "$HARNEX_SPAWNER_PANE" "worker-42 done" Enter
EOF
)"
```

### Example: watch for doc drift during implementation

A buddy that checks whether a worker's code changes have left
docs out of date:

```bash
harnex run pi --id worker-99 --tmux worker-99
harnex run pi --id buddy-99 --tmux buddy-99
harnex send --id buddy-99 --message "$(cat <<'EOF'
Watch harnex session worker-99.
Every 5 minutes: run `harnex pane --id worker-99 --lines 30`.
When the worker goes idle after making changes, run `git diff --name-only`
and check whether any changed code has corresponding docs (README, GUIDE,
inline comments) that are now stale. If so, nudge the worker:
  harnex send --id worker-99 --message "Docs may be stale — check README
  sections related to <specific area>."
When the worker exits, report a summary to the invoker:
  tmux send-keys -t "$HARNEX_SPAWNER_PANE" "worker-99 done. Doc drift: <yes/no>" Enter
EOF
)"
```

### The invoker doesn't need to be a harnex session

Every spawned session gets `$HARNEX_SPAWNER_PANE` — the tmux pane ID
of whoever ran `harnex run`. The buddy can report back to a plain
Claude Code session, a Codex session, or any tmux pane:

```bash
tmux send-keys -t "$HARNEX_SPAWNER_PANE" "worker-42 finished" Enter
```

See [recipes/03_buddy.md](recipes/03_buddy.md) for the full pattern.

## All commands

| Command | What it does |
|---------|-------------|
| `harnex run <cli>` | Start an agent (`--tmux` visible, `--detach` background, `--watch` built-in monitoring) |
| `harnex send --id <id>` | Send a message (queues if busy, `--wait-for-idle` to block until the turn returns idle) |
| `harnex stop --id <id>` | Send the agent's native exit sequence |
| `harnex status` | List running sessions; with `--id ID --json`, terminal summaries can classify completed/failed sessions after exit |
| `harnex watch --id <id>` | Safely monitor existing visible/detached work until `done`, `task_failed`, or timeout; optional done/fail markers |
| `harnex pane --id <id>` | Capture a tmux-backed session's screen (`--follow` for live) |
| `harnex logs --id <id>` | Read session transcript (`--follow` to tail) |
| `harnex events --id <id>` | Stream structured session events (`--snapshot` for non-blocking dump) |
| `harnex history` | List completed dispatches from `.harnex/dispatch.jsonl` |
| `harnex wait --id <id>` | Block until process exit by default; use `--until done` for unattended work completion or `--until task_complete` for exact structured turn completion |
| `harnex doctor` | Run adapter dependency preflight checks; add `--sweep` for read-only session drift diagnostics |
| `harnex guide` | Getting started walkthrough |
| `harnex agents-guide` | Agent-facing dispatch, chain, buddy, monitoring, and naming guides |
| `harnex recipes` | List and read tested workflow patterns (`show 01`, `show buddy`) |

## Uninstalling

```bash
gem uninstall harnex
```

If you installed harnex skills with an older release, those copies are no
longer used. Remove stale `~/.claude/skills/harnex-*` or
`~/.codex/skills/harnex-*` entries manually if you want to clean them up.

## Going deeper

- [GUIDE.md](GUIDE.md) — getting started walkthrough with examples
- [TECHNICAL.md](TECHNICAL.md) — full command reference, flags, HTTP API, architecture

## License

[MIT](LICENSE)
