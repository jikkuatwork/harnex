# Changelog

## [0.29.1] - 2026-10-23 | 10:31 AM | IST

Fix release for #88: lanes in repos with a phase allowlist. Published to
RubyGems on 2026-10-25 | 02:14 AM | IST.

### Fixed

- In a repo whose `.harnex/config.json` phase allowlist has
  `"policy": "reject"`, harnex refused every `delegate`, `ask --write` and
  `reply` (`meta.phase (none) is not allowlisted`). The run behind a lane
  is now tagged with phase `delegate` or `ask`. These are harnex's own
  phases, like `preflight`, so every allowlist accepts them.
- A lane that harnex refused before the worker started left a `failed`
  record, so a retry under the same name failed with `lane NAME already
  exists (failed)` until `discard`. Now a refused new lane leaves no record
  and no brief. A refused `reply` keeps the state the lane's last turn left.
  The next `delegate` under the same name also clears a record left this way
  by 0.29.0.

### Added

- `harnex delegate --phase NAME` and `harnex ask --phase NAME` tag a lane
  with a work phase such as `implement`. The repo allowlist checks a named
  phase, and `reply` reuses it.

## [0.29.0] - 2026-10-22 | 06:08 PM | IST

**The agent release.** harnex becomes a tool your coding agents use directly:
hand a question or a task to a Pi worker (GPT by default) and get the reply
back as plain text, with a footer saying what happened and what to do next.
This entry summarizes 0.22.0–0.29.0, the first public release since 0.12.0.
Website and docs: <https://harnex.zyt.app>. Upgrading:
`docs/upgrading-to-0.29.md`.

### Highlights

- **Lanes** (0.22):
  - `harnex delegate [--worktree NAME]` hands a task to a worker, optionally
    in its own git worktree;
  - `result` collects parallel lanes;
  - `reply` follows up with the worker's context (a finished lane resumes its
    Pi session);
  - `land` merges and cleans up; `discard` drops a lane; `lanes` shows what
    each worker is doing right now.
- **`harnex mcp`** (0.23): the same verbs as native MCP tools for Claude Code,
  Pi and any MCP client. Long calls report progress, and Claude Code moves them
  to the background and notifies on completion. `harnex mcp install`
  registers it for both clients.
- **The `gpt` subagent for Claude Code** (0.21, MCP relay since 0.23): ships
  as `agents/gpt.md`, and `harnex mcp install` installs it.
- **Smoothness work** (0.24–0.28), measured with `evals/agents/run`. Real
  Claude Code and Pi supervisors, with and without MCP, run seven scenarios;
  0.28 passed two consecutive full rounds (28/28 each) with no harnex usage
  errors, no doc lookups and nothing left behind. Along the way:
  - progress detail;
  - the hand-merge sweep;
  - model-failure next steps;
  - forgiving flags and MCP arguments;
  - workers never see harnex's own MCP tools.

### Breaking (since 0.12.0)

- Codex adapters, the JSON-RPC transport, `run --fast`/`--legacy-pty` and
  `preflight --legacy-pty` were removed (0.20); harnex is Pi + GPT first.
- `harnex ask` waits 9 minutes by default (0.22); use `--timeout none` for no
  cap.
- Pi starts with `--no-approve` unless `-- --approve` is passed (0.22).

### Added in 0.29.0

- **Docs:**
  - `docs/lanes.md`, `docs/mcp.md`, `docs/agents.md` and
    `docs/upgrading-to-0.29.md`;
  - `GUIDE.md` now starts with lanes;
  - `TECHNICAL.md` gains a "Lanes and MCP" architecture section.
- **The website** `site/`: a monospace, terminal-styled site built from these
  docs and the live CLI help, deployed as a Holm app to harnex.zyt.app.
- **The `gpt` agent ships in the gem** (`agents/gpt.md`). `harnex mcp
  install` installs it at `~/.claude/agents/gpt.md` unless one exists
  (`--no-agent` skips it). `uninstall` removes only an unmodified copy.
- **Gem metadata:** a new summary and description, plus documentation and
  changelog links.

### Changed

- Examples use generic model names (`openai/gpt-5.1`).

## [0.28.0] - 2026-10-22 | 05:15 PM | IST

Owner-authorized local-only release (#87): fixes from round B on 0.27.0.

### Changed

- The MCP `ask` tool description, `harnex ask --help` and the skill index
  say that an ask worker only reads and cannot run commands; to run tests,
  scripts or benchmarks, use `delegate`. In round B, a relay sent "run
  bin/slow-bench" to a read-only ask, and the worker could only read the
  script.
- Outside this repo: the `gpt` relay routes a brief that asks to run
  something or change files to `delegate` (in place), questions and reviews
  to `ask`, and honours `mode: read`.
- Evals: `bin/slow-bench` prints a random score and records it in
  `.git/bench-last-score`. S4 and S6 pass only when the benchmark really
  ran and the answer quotes that score; a fixed score in the script could
  be read without running it.

## [0.27.0] - 2026-10-22 | 04:58 PM | IST

Owner-authorized local-only release (#87): fixes from round A on 0.26.0
(27/28 pass, 0 leftovers, 0 doc lookups).

### Changed

- MCP tools accept the argument names agents reach for from their other
  tools:
  - `prompt`, `brief`, `message` or `instructions` for `task`;
  - `prompt` or `query` for `question`;
  - `prompt` or `text` for `message`;
  - `lane`, `id` or `worktree` for `name`;
  - `name` or `lanes` for `names`.

  A supervisor passed `prompt` to `delegate` and got "task is required".
- Evals: `--resummarize DIR`, and an `HxErr` column that counts harnex
  usage friction apart from worker failures harnex reported properly.
- Outside this repo: the `gpt` agent's description says that `harnex lanes`
  (or the `lanes` tool) shows what a running worker is doing.

## [0.26.0] - 2026-10-22 | 04:40 PM | IST

Owner-authorized local-only release (#87): fixes from the first full 0.25.0
eval round (28/28 pass).

### Added

- `harnex land` with no name, and the MCP `land` tool without `names`,
  land every finished worktree lane the caller started in this repo,
  oldest first. A supervisor called `land {}` expecting this. `discard`
  still requires names.
- `harnex doctor` reports `integrations`: whether the harnex MCP server is
  registered for Claude Code and Pi, whether the `gpt` agent is linked, and
  a hint to run `harnex mcp install`.
- Closed lane records and their briefs are pruned after 30 days; open lanes
  never are.

### Changed

- README: `harnex mcp uninstall` before `gem uninstall`.

## [0.25.0] - 2026-10-22 | 04:14 PM | IST

Owner-authorized local-only release (#87).

### Fixed

- **Workers never get harnex's own MCP tools.** With harnex MCP registered
  in Pi, every harnex-launched Pi worker also saw `delegate` and the other
  harnex tools, and Pi 1.4.0 keeps MCP tools despite a `--tools` allowlist.
  In an eval, a read-only ask worker used `delegate` to launch a writable
  lane. Now:
  - Pi workers start with `--exclude-tools mcp__harnex__…` (merged with the
    caller's own exclusions; Pi >= 0.99);
  - allowlisted (read-only) workers start with `--no-mcp` (Pi >= 1.0.4).

### Changed

- Progress lines read `now bash 12s`, without nested parentheses.
- Lane names generated from a task skip filler words (`pi-slow-bench`, not
  `pi-run-the-slow-bench`).
- Evals lift Claude print mode's 10-minute background ceiling
  (`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`), as interactive sessions have
  none. S6 accepts `tmux capture-pane` as checking on a worker.

## [0.24.0] - 2026-10-22 | 03:51 PM | IST

Owner-authorized local-only release (#87): fixes from the 0.23.0 agent evals.

### Added

- **What a worker is doing now.** The live activity snapshot records the
  current tool's name and the turn's tool-call count. Tool arguments are
  still never retained.
  - MCP progress shows it: `wc: working 2m10s · 7 tool calls · now bash (12s)`.
  - So does `harnex lanes`: `working (now bash 12s)`.
  - MCP names ask and delegate lanes up front so progress can follow them.
- **Hand merges are tidied.** A lane whose branch was merged by hand (into
  HEAD, worktree clean, at least one commit) is marked landed, and its
  worktree and branch are removed on the next `delegate`, `result` or
  `lanes`.
- **Clearer next steps in the footer.**
  - Model and provider failures suggest retrying on Pi's default model:
    `harnex reply NAME "Continue..." --model provider/model` keeps the task
    through the lane's Pi session.
  - Lanes with no commits say there is nothing to merge.
  - Done lanes say `land` merges and cleans up (instead of `git merge`); the
    MCP instructions say the same.
- **Evals:**
  - two new scenarios: S6 (check on a running worker) and S7 (recover from
    a broken model);
  - the exit-124 continuation no longer counts as a tool error.

## [0.23.0] - 2026-10-22 | 03:28 PM | IST

Owner-authorized local-only release (#87).

### Added

- `harnex mcp`: a stdio MCP server exposing `ask`, `delegate`, `result`,
  `reply`, `land`, `discard` and `lanes` as native tools for Claude Code, Pi
  and any MCP client. Each tool runs the CLI verb and returns its text.
  - Blocking calls send `notifications/progress` every 15s; the default wait
    is 25 minutes.
  - Calls run concurrently.
  - A cancel stops the wait, never the worker.
- `harnex mcp install|uninstall|status`: register the server for Claude Code
  (`claude mcp add --scope user`) and Pi (`~/.pi/agent/mcp.json`, exposure
  `direct`, 2h request timeout). It registers the RubyGems wrapper, so no
  version-manager shim or client cwd is involved.
- `harnex doctor` capabilities add `mcp`.
- Lane verbs accept habits from `harnex run` instead of refusing them:
  - `--id` and `--tmux [NAME]` name the lane;
  - `--auto-stop` and `--wait-done` are accepted and ignored;
  - `--wait-timeout` is an alias for `--timeout`;
  - `--context` and `--context-file` give the task;
  - `reply` takes `--id` and `--message`.
- `evals/agents/run` routes: `claude-cli` (no MCP, no `gpt` agent) and
  `pi-cli` (`--no-mcp`) beside the configured `claude` and `pi`.

## [0.22.0] - 2026-10-22 | 03:07 PM | IST

Owner-authorized local-only release (no RubyGems publication); breaking
changes allowed (#87). Plan: `koder/plans/39_agent_smoothness.md`.

### Added

- **Lanes: a small agent-facing layer over Pi workers.**
  - `harnex delegate [--worktree NAME] TASK`: one call hands a task to a
    worker and prints its reply plus a lane footer: state, time, model, cost,
    commits, diffstat and next commands. `--worktree NAME` creates
    `.harnex/worktrees/NAME` on branch `harnex/NAME`. `--no-wait` starts
    parallel lanes.
  - `harnex result [NAME...]`: wait for lanes and print each result as it
    lands. With no names it covers every uncollected lane the caller
    started in this repo.
  - `harnex reply NAME MESSAGE`: a follow-up. A busy worker takes it
    mid-turn; a finished lane is relaunched on its own Pi session
    (`pi --session`), so it keeps its context.
  - `harnex land NAME`: merge `harnex/NAME` into the current branch, then
    remove the worktree and branch. Leftovers are committed first; a
    conflict leaves the merge in progress for the caller.
  - `harnex discard NAME` and `harnex lanes`.
  - Lane records live in `STATE_DIR/lanes/`. Blocking commands default to
    `--timeout 9m`, and exit 124 names `harnex result NAME`.
- `harnex wait --since TIME` ignores events from an earlier launch of the
  same id (each launch restarts the events-log seq).
- `harnex doctor` capabilities add `lanes`.
- `evals/agents/run`: agent smoothness evals. Real supervisors (Claude Code
  headless, Pi print mode) run five scenarios against a fixture repo,
  scored for correctness, tool calls, errors, doc lookups and leftovers.

### Changed

- **Breaking:**
  - `harnex ask` defaults to `--timeout 9m` (`none` for no cap).
  - Every ask is a lane, so a timed-out ask names `harnex result ID`, and
    `harnex reply ID "..."` follows up with the worker's context.
    `ask --resume ID` still works and no longer needs `--repo`.
  - Pi starts with `--no-approve` unless the caller passes `--approve`.
- Top-level `harnex --help` leads with the agent verbs;
  `harnex agents-guide claude` is rewritten around them.
- Help examples use Pi session ids (`pi-i-42`) instead of Codex-era ones.

### Fixed

- Harnex state in a repo no longer shows up as untracked work: writing a
  dispatch row under `.harnex/` adds `.harnex/` to the clone's
  `info/exclude`. This also unblocks `git worktree remove` for lane
  worktrees.

## [0.21.0] - 2026-10-22 | 12:40 PM | IST

Owner-authorized local-only release (no RubyGems publication). Makes Pi/GPT
workers usable as a Claude Code subagent type (#86 slice 1): the `gpt` agent
(kept in `~/Projects/pi/.claude/agents/gpt.md`) relays briefs through
`harnex ask` and needs `ask --resume` to outlast the 10-minute Bash cap.

### Added

- `harnex ask --resume ID --repo ROOT [--timeout DUR]` (#86): keep waiting on
  an ask that timed out and print its answer like the original ask (same
  exit codes, the full answer even when truncated in the result). A timed-out
  ask now names this command on stderr instead of a raw `harnex wait`, so a
  Claude Code subagent loops on one command shape under the 10-minute Bash
  cap. `--json` output still carries the run's own `resume` field.
- `harnex doctor` capabilities add `ask_resume`.

## [0.20.0] - 2026-10-20 | 09:55 PM | +04

Owner-authorized local-only release (no RubyGems publication). Harnex is now
Pi + GPT only: Codex support is removed (owner decision 2026-10-20: "we are
going to be exclusively pi & gpt models").

### Removed

- The `codex` (PTY) and `codex app-server` (JSON-RPC) adapters, the
  `stdio_jsonrpc` session transport, the app-server client, and their
  fixtures and tests. `harnex run codex` is no longer special-cased (it would
  wrap a `codex` binary as a generic PTY CLI).
- `harnex run --fast` and `--legacy-pty`; Codex service-tier forcing;
  `harnex preflight --legacy-pty`; `docs/codex-appserver.md`.
- `harnex doctor` Codex checks: it now checks Pi by default and only Pi
  (`--adapter pi|all`).
- Issues #40, #42 and #43 (Codex recovery/fallback/throughput work) closed.

### Changed

- Shared session behavior previously tested through Codex (receipts and
  claims, completion-notification ordering, boot-failure classification,
  stop sequencing, auto-stop, status fields, usage pricing, `preflight`
  end to end) is now tested through Pi or adapter-neutral fakes.
- Dispatch-row schema fields are unchanged; `agent.service_tier`,
  `actual.rate_limits` and Codex error details stay `null` for new rows.
- `harnex doctor` capabilities add `ask`, `final_message` and `owner_tag`.
- Docs, guides, recipes and repo instructions are Pi-only; session ids use
  `pi-<role>-<tag>`.

## [0.19.0] - 2026-10-20 | 06:35 PM | +04

Owner-authorized local-only release (no RubyGems publication). Makes Pi
(GPT-backed) workers usable as native tools from Claude Code sessions and
subagents (#85), driven by live Claude-subagent stress runs.

### Added

- `harnex ask "QUESTION"`: one blocking call that hands a question to a Pi
  worker (read-only tools by default; `--write` to allow edits) and prints its
  answer. `--model`, `--fallback-model` (one more try on provider capacity),
  `--effort`, `--file/--section`, `--timeout`, `--json`; stderr names the
  lane, time and model. A read-only ask records in the global stream, so the
  repository stays untouched.
- Turn results carry the worker's reply: `final_message` (at most 4,000
  characters), `final_message_path` (full text), `final_message_truncated`,
  plus the lane's `end_sha`, `commits` (since launch), `turn_commits` and
  `model`, in events, `wait`, `send --wait-done` and owner-stream lines.
- `harnex run --wait-done [--wait-timeout DUR]`: launch and block until the
  first turn's result in one call; on 124 the output names the `resume`
  command.
- `--owner-tag TAG` on `run` and `watch --owner`: a subagent's own owner
  (`<session>/<TAG>`), so its stream holds only its lanes and no backlog.
- `watch --owner --match GLOB` filters lanes by id; `--until-idle` blocks
  until no matching lane is running and prints every result on the way.
- `send --stall-after DUR` (with `--wait-done`); `send --wait-done` timeouts
  print `resume`.
- Status and stall lines name Pi's running shell commands
  (`running_commands`; "stalled … while running `sleep 150`").
- `harnex agents-guide claude`: the operating guide for Claude Code.

### Changed

- `watch --owner --once` prints every event ready in its pass, not only the
  first.
- The owner stream delivers each turn's result once and in settle order, even
  when several turns end between polls (owner records keep a bounded
  per-turn history). Previously a turn replaced by the next before a poll was
  lost.
- `harnex send` to an exited session fails fast (exit 1, `status: "exited"`)
  instead of spending its whole timeout on lookup.
- `send --wait-done` output: `status` is the turn's verdict and
  `delivery_status` the delivery's.
- `wait --until done` on a session already gone reports `process_state:
  "exited"` and names a caller's stop `stopped_by_caller`.
- Stall lines carry `turn` and `elapsed_s`; durations under 10 minutes print
  as `3m05s`.
- Durations accept compound forms (`8m30s`, `1h30m`); `--context-section`
  accepts a heading with its marks (`"## Task"`).
- A follow-up whose run settled while the send was in flight is sent as a
  plain prompt, and follow-ups are counted for the turn they joined.
- `resume` hints name the checkout's `bin/harnex` when running from source.

## [0.18.0] - 2026-10-20 | 04:41 PM | +04

Owner-authorized local-only release (no RubyGems publication). Closes the
subagent-orchestration gaps found by Holm Queues 159/160 (#79-#84).

### Added

- `harnex run --context-file PATH [--context-section TEXT]` sends a brief from
  disk, or only the part after a heading (to the next heading of its level)
  or a plain marker line (to end of file), and refuses an empty result.
  `--meta-file PATH` reads `--meta` JSON from a file (inline `--meta` keys
  win). The brief path and SHA-256 of the sent text land in
  `meta.context_file` / `meta.context_sha256` (#83).
- `harnex watch --owner --once [--timeout DUR] [--cursor NAME]`: print the
  first undelivered result or stall, advance the cursor, exit 0 (124 on
  timeout). One blocking call covers every lane an owner launched; named
  cursors keep a parent and its subagent apart (#84).
- Per-turn completion (#81): `harnex send` reports `after_seq`;
  `harnex wait --until done --after-seq N` waits for the turn after that point;
  `harnex send --wait-done` does both in one call. `task_complete` /
  `task_failed` events carry `turn`, and the owner stream reports every turn's
  result (a nudged turn included) instead of one per session.
- `provider_capacity` outcome class: a Pi turn that fails after Pi's own
  provider retries ran out (`auto_retry_end success:false`). In status JSON,
  dispatch rows, the owner stream and `orchestration report`; fatal by default
  for `--failure-budget`, as `task_failed` was (#82).
- Turn results carry `follow_ups: {sent, pending}` when follow-ups joined the
  turn (from Pi's `queue_update` counts; `pending: 0` means each reached the
  model), and owner events add `settled_at`. A later turn's `elapsed_s` runs
  from that turn's start. `harnex run --tmux` prints `tmux_target`.

### Changed

- A send to a busy Pi session is handed to Pi at once as a follow-up
  (`delivery: "follow_up"`), delivered when the current turn ends, instead of
  waiting in the 120 s inbox and expiring unread. Other adapters: an expired
  message makes `send` exit 1 with `status: "expired"`, and a send that times
  out withdraws its queued message before exiting 124 (#79).
- Worktree lanes (`--cwd` in a different Git toplevel than `--root`) are
  observed in the lane: `commit_sha`, branch, receipt, activity and acceptance
  describe the lane; the end row adds `root_commit_sha` (#80).
- `run --tmux --context-file` hands the brief to the inner runner by path,
  so long briefs no longer hit tmux's command-length limit.

## [0.17.0] - 2026-10-18 | 01:13 PM | +04

Owner-authorized local-only release (no RubyGems publication).

### Added

- `harnex watch --owner [ID]`: one owner-scoped stream of compact JSON lines
  (`harnex.owner_event.v1`, with a readable `msg`) for every dispatch an owner
  started: `started`, `done`, `rejected`, `failed`, `stalled` (with
  `--stall-after`), `stopped`, `timeout`. No heartbeats; runs until killed or
  `--max-wait`. A per-owner cursor delivers each result once across restarts.
  Built for Claude Code's `Monitor` (#77).
- `harnex run` from a Claude Code Bash shell records `CLAUDE_CODE_SESSION_ID`
  as the dispatch owner, as Pi does with `PI_SESSION_ID` (Pi's wins if both
  are set; explicit `--orchestration-session-id` wins over both). The tmux
  hand-off marks the owner resolved, so a tmux server's stale environment
  cannot re-attribute a dispatch.
- Documented the stable `harnex status --json` fields for status-line and
  panel consumers.

## [0.16.1] - 2026-10-18 | 12:41 PM | +04

Owner-authorized local-only release (no RubyGems publication).

### Added

- `harnex watch --stall-after DUR` (and `wait --until done --stall-after DUR`)
  exits 4 (`wait_result: stalled`) once the live session shows no progress for
  DUR, leaving the worker running. Pi and other structured adapters use the
  most recent turn-start/model/tool event during an active turn
  (`clock: activity`); PTY adapters fall back to transcript idle
  (`clock: output_log`). Stalls write no marker and skip
  `--stop-on-terminal`. The predicate (`Harnex::Stall`) is shared for #77
  (#76).

## [0.16.0] - 2026-10-18 | 12:55 AM | +04

Owner-authorized local-only release. Owner decision (2026-10-18): Harnex is
installed locally and is not published to RubyGems.

### Added

- Final gates: `harnex run --final-gate '<cmd>'` (repeatable; or meta
  `final_gates`) declares final acceptance commands. Receipts gain
  `validation.commands_had_failures` (whole-history, harness-observed) and
  `validation.final_gates` (`declared`, `observed_pass`, `observed_fail`,
  `missing`, `status: pass|fail|unknown|undeclared`, per-gate last exit).
  With gates declared, `validation.status` reports them, so an exploratory or
  intermediate failure no longer marks a green final run as `fail`. Matching
  is exact, after unwrapping a single `bash -lc`/`sh -c` transport wrapper.
  Without gates, behavior is unchanged. Diagnostics only: acceptance and
  outcome classes do not change (#68).
- Dispatch-row `outcome.class` gains process classes from signals Harnex
  already holds: `boot_failure`, `permission_prompt`, `timeout`,
  `stopped_by_caller`, `process_failed`. They refine an `unknown`/`task_failed`
  terminal or the receipt rejection of a process that never signalled
  completion; completion and proof verdicts are never overridden, and the
  vocabulary is closed with an `unknown` fallback.
- `harnex orchestration report` counts worker outcome classes per raw attempt
  and per retry family (joined by parent attempt/dispatch id), accepts
  `--queue-id` as well as `--run-id`, and takes an optional
  `--failure-budget N [--budget-unit attempts|families] [--fatal-classes A,B]`
  that adds a `failure_budget` verdict and exits 3 on breach (#57).
- `harnex preflight ADAPTER [--cwd DIR] [--commit-check]` runs one tiny real
  dispatch through `harnex run` and prints a JSON verdict
  (`harnex.preflight.v1`): registration, boot, permission prompt, task read
  from the task root (default `/tmp`), workspace write, harness-observed
  command exit (via a final gate), receipt, worker claims, completion, and
  stop, plus a scratch-repo commit with `--commit-check`. Each failure is a
  distinct check and failure class; a turn that fails before any work reports
  its (redacted) error as the root cause. Usage, cost and context telemetry
  provenance is reported per adapter. Exits non-zero on any failed check. Its
  dispatch row carries `phase=preflight` (exempt from repo phase allowlists)
  and `orchestration report` excludes such rows unless `--include-preflight`.
  Workers are stopped through the session API and carry a `--max-runtime`
  backstop, so a killed or timed-out preflight cannot orphan them (#56).
- `harnex doctor` capabilities add `final_gates: 1`, `outcome_classes: 1` and
  `preflight: 1`.

### Changed

- `harnex status` (default current-repo view) now says how many sessions are
  active in other repos, with up to three ids, instead of a bare
  "No active harnex sessions" that read as global emptiness when workers run
  in sibling worktrees. `--repo`, `--all` and `--json` output is unchanged
  (#26).
- A bare `harnex wait` (process-exit fence) prints a stderr `note:` when the
  session was not started with `--auto-stop`, and again if its turn settles
  while the wait is blocked, pointing at `--until done`. Events from an
  earlier run of the same id are ignored. Status JSON gains `auto_stop` (#49).
- Events JSONL `ts` now has millisecond precision (`iso8601(3)`), so teardown
  races can be measured from the events log (#36/#37 follow-up). Readers that
  parse ISO-8601 are unaffected; older rows keep whole seconds.

### Fixed

- Two status tests that sat below a `private` keyword never ran; they run now.
- Test-suite flakes: cross-repo status hint tests no longer see registries
  leaked by other suites, and the detached on-done smoke waits for teardown.

## [0.15.0] - 2026-10-16 | 07:20 AM | +04

Owner-authorized local-only release; public publication, tag and push remain deferred.

### Added

- Pi RPC receipts now attest built-in `bash` commands: bounded command text,
  integer exit from `result.structuredContent.exit_code`, status and duration,
  correlated by `toolCallId`. Output is never persisted. Pi bash calls count in
  `commands_executed`; other tools stay `tool_calls` (#70).
- Receipts gain `command_observation: "partial"` and
  `observed.commands_unobserved`: Pi command calls without structured exit
  evidence (abort, timeout, extension override, older Pi, in flight at
  teardown) are counted rather than inferred, and `validation.status` reads
  `unknown` instead of `pass` while any exist. Live verified on Pi 1.2.0/1.3.0.
- `harnex doctor` advertises `capabilities.pi_command_proof: 1`; consumers
  should check it before treating Pi receipt commands as proof.

### Fixed

- `wait`/`watch` observers no longer exit 1 when a sibling session's registry
  file is removed between the session scan's glob and read (stop/cleanup
  race); `doctor`'s registry sweep is guarded the same way (#75).

## [0.14.1] - 2026-10-05 | 09:55 PM | +04

Owner-authorized local-only release; public publication, tag and push remain deferred.

### Fixed

- New dispatch records and reconciliation repair appends store paths under the
  user's home as `~`/`~/...`, without mutating runtime records or rewriting
  existing rows. Nested data and home-prefix boundaries are preserved (#74).
- Canonical reconciliation accepts equivalent absolute and home-relative paths
  while retaining genuine payload conflicts. Status results keep their absolute
  repository roots, and retention still protects portable live-record paths.

## [0.14.0] - 2026-09-28 | 08:25 PM | +04

Owner-authorized local-only release; public publication, tag and push remain deferred.

### Fixed

- Explicit idle Pi shutdown preserves the latest settled accepted/no-change
  proof, including follow-up turns. Busy/newly dispatched work cannot reuse an
  older receipt; unexpected transport loss and malformed output still fail.
  Raw child exits remain observable separately from logical cleanup status (#69).
- `wait`/`watch` observer deadlines now include slow registry, event, HTTP and
  exit-grace probes. A private observer process enforces the monotonic cap without
  stopping the worker; late results cannot override timeout (#71).

### Added

- Opt-in `wait/watch --heartbeat DUR` streams flushed diagnostics on stderr while
  preserving one final JSON stdout result. `wait --max-wait` aliases `--timeout`.
- Structured work/model/tool activity clocks distinguish real events from UI/log
  freshness, with unknown PTY clocks and no retained thinking-stream content.
- Bounded stop reason/origin survives events, status, receipts and dispatch-end
  telemetry. Expected cancellation is distinct from provider disconnection.
- `run --max-runtime DUR` enforces a fixed runner-owned worker budget independent
  of supervisors, prompts, retries or UI chatter. Active expiry fails work; idle
  cleanup preserves accepted proof. Doctor exposes versioned capabilities (#71).

## [0.13.0] - 2026-09-23 | 01:56 AM | +04

Local-only activation approved by the owner. Public RubyGems publication, Git
tag, and push are deferred; later publication must use the exact verified gem
built from this commit rather than rebuilding version 0.13.0.

### Added

- Dispatch telemetry now has an opt-in local archive bridge. A stable sidecar
  lock encloses archive preparation and append, preventing atomic rotation from
  stranding writers on an old inode. A separate complete-history reader feeds
  history, canonical reconciliation, latest-row lookup, status, and attempt
  accounting. Helper failures never drop a new dispatch row, while unavailable
  or malformed complete history fails explicitly instead of appearing empty.
- `harnex telemetry archive-capability --json` exposes the local helper protocol
  version and exact archiver/history environment names so automation can refuse
  to trim active dispatch history against an older installed Harnex.

## [0.12.1] - 2026-09-19 | 12:30 PM | +04

### Fixed

- Pi-launched dispatches now capture the invoking primary's `PI_SESSION_ID`
  before crossing detached/tmux process boundaries and publish a durable,
  owner-addressed, per-attempt completion record. Reusing a dispatch name no
  longer erases an unacknowledged attempt, and nested workers never implicitly
  nominate themselves as completion consumers.
- Addressed delivery registration fails before the initial structured prompt
  when it cannot be persisted. A terminal delivery-write failure leaves the
  registered running record available for native `harnex watch` recovery.
  Existing typed markers and optional `--on-done` hooks remain compatible.

## [0.12.0] - 2026-09-03 | 10:09 AM | IST

### Added

- Registered sessions now atomically publish a typed completion marker under
  `$HARNEX_STATE_DIR/done/` at the first accepted, rejected, failed, or error
  work result, without requiring a `wait` or `watch` client.
- `harnex run --on-done CMD` launches one non-blocking trusted local shell hook
  with typed completion, receipt, commit, and elapsed-time environment values.
  The option works in foreground, detached, and tmux launches.

### Changed

- `harnex status` now renders settled live work (`done`, `rejected`, or
  `failed`) ahead of an adapter's prompt/busy state. Existing JSON fields and
  the v2 dispatch envelope remain unchanged.

## [0.11.0] - 2026-08-14 | 01:03 PM | IST

### Fixed

- Pi RPC completion now fences on Pi 0.80.4+'s `agent_settled` event instead of
  the lower-level `agent_end`. Provider retries, compaction recovery, and queued
  continuations can no longer publish premature `task_complete` or open the
  inbox early. Final `error`, `aborted`, and `length` stop reasons fail closed;
  a settled run without an authoritative final assistant reason also fails.
- Pi 0.84's breaking delta-only `message_update` shape is correlated from
  `message_start` through authoritative `message_end`, preserving streamed
  output without duplicating the final message.
- Harnex `--model` and `--effort` now become supported Pi `--model` /
  `--thinking` startup controls and are verified through RPC `get_state`,
  instead of adding ignored fields to `prompt` or persisting RPC setters into
  the user's Pi defaults. Model mismatches and clamped effort requests fail
  before prompting, telemetry distinguishes requested from observed effective
  model values, and forced busy sends use Pi's `steer` streaming behavior.
- Pi RPC request waits are bounded, subprocess stderr is continuously drained
  into a bounded diagnostic tail, and process status is read from Open3's wait
  thread instead of racing it with a second `waitpid` and potentially losing a
  nonzero exit status.

### Changed

- **Compatibility:** structured Pi dispatch now requires Pi >= 0.80.4. Both
  foreground and detached/tmux launches validate the installed version before
  spawn. This is the first Pi release with the final `agent_settled` fence.
- Pi retry/compaction events retain settlement state and expose current
  summarization-retry lifecycle events in Harnex's event stream.
- Codex schema fixtures are refreshed against CLI 0.147.0 after a bounded
  semantic review. The drift is limited to a string path-alias replacement and
  additive optional thread/item fields that Harnex does not consume; existing
  minimal response fixtures still validate, so no Codex adapter behavior
  changes.

### Added

- `harnex doctor --adapter pi` statically verifies the Pi RPC version;
  `--adapter all` checks both Pi and Codex while the no-argument default remains
  Codex-compatible.
- `docs/pi-rpc.md` documents transport semantics, project trust, lifecycle,
  model controls, telemetry, and known boundaries. An opt-in live contract test
  (`PI_INTEGRATION=1`) verifies the installed Pi event shape without adding
  provider cost to the normal suite.

## [0.10.2] - 2026-08-08 | 06:49 PM | IST

Docs-only patch: no library or CLI behavior changes. Released so the
packaged `agents-guide` surfaces serve the corrected guidance instead of the
stale 0.10.1 copies.

### Changed

- `guides/04_monitoring.md`: the Completion Test's clean-tree check now
  documents excluding the harness-owned dispatch stream
  (`git status --short -- . ':!.harnex'`) in repos that track
  `.harnex/dispatch.jsonl`. New anti-patterns: claiming "no live sessions"
  from memory (finished agents park at prompts — sweep proven-done sessions,
  then prove with `harnex status`) and failing clean-tree fences on
  dispatch-stream growth.
- `docs/dispatch-telemetry.md`: new "Clean-Tree Checks And The Tracked
  Stream" section — the tracked stream grows mid-run and is harness-owned;
  fences and worker briefs must exclude it and never revert it.

Context: holm Analysis 803 (queue-process failure meta-analysis). During
Q107 g2 a worker aborted after misreading dispatch-stream growth as foreign
dirt, and a coordinator claimed "no live sessions" while 12 completed
workers sat parked at prompts.

## [0.10.1] - 2026-08-04 | 12:20 AM | IST

Patch release: closes the recovery and regression-checking gap left
after `0.10.0` removed the upstream telemetry mirror. The canonical
`.harnex/dispatch.jsonl` stream remains the only writer; this release adds
operator tooling to prove and repair that stream without schema migration.

### Added

- `harnex telemetry assert-canonical` validates the canonical dispatch stream
  and, when explicit `--source` paths are supplied, fails closed on missing or
  conflicting rich end rows. It is read-only, tolerates mixed-era history
  including open v2 starts and legacy rows, and emits bounded redacted reports.
- `harnex telemetry reconcile` uses the same analysis, defaults to dry-run, and
  only appends missing rich end rows when `--apply` is passed. It never rewrites,
  deletes, sorts, migrates, cleans source files, or discovers sources
  automatically.
- Source paths may be files or directories. Directory scans are bounded to
  `.json`/`.jsonl`, skip `.git`, symlinks, and the resolved canonical stream,
  ignore unrelated generic JSON, and treat identity or payload conflicts as
  zero-write failures.

## [0.10.0] - 2026-08-03 | 01:44 PM | IST

Minor bump, **breaking**: `--summary-out` is removed outright, so the canonical
`.harnex/dispatch.jsonl` is the only telemetry destination. Also fixes four
runner reliability defects found while verifying that removal — concurrent
registry corruption, a delivered send reported as failed, a corrupt registry
entry crashing every session scan, and a closed stdout wedging the wrapped
agent.

### Fixed

- **Concurrent registry writes no longer corrupt each other** (#66).
  `write_registry` derived its temp path from the pid alone, but several
  threads in one session write the same registry — the startup persist, the
  inbox delivery thread, and one thread per API client. One thread renamed the
  file another was still writing, and the loser raised `Errno::ENOENT`
  (2080 failures in a 2400-write reproduction; now zero). Writes are also no
  longer defeated by a state directory that was reaped mid-session.
- **A failed registry write no longer fails an already delivered send** (#66).
  Registry persistence runs *after* the prompt has reached the agent, so a
  bookkeeping failure was reporting a dispatched turn as failed — enough to
  make an orchestrator retry work already in flight. Post-injection refresh now
  warns; startup persistence stays strict so an undiscoverable session still
  fails loudly instead of running unreachable.
- **One corrupt registry file no longer crashes every session scan** (#66).
  A non-numeric pid raised `ArgumentError` out of `active_sessions`, taking
  down `harnex status`, `harnex send`, and `harnex pane`. Such an entry is now
  treated as dead and pruned, matching the existing self-healing for
  unparseable JSON.
- **A closed stdout no longer wedges the wrapped agent** (#66).
  `Errno::EPIPE`/`EBADF` are not `IOError` subclasses, so they escaped the
  output reader's rescue and killed the thread; the PTY then stopped draining
  and the agent blocked forever on write, presenting as an agent hang with no
  harness error. Draining is now unconditional and stdout echo is best-effort.
  Both reader loops report an unexpected exit instead of vanishing silently.
- `Retention` metadata writes route through the shared atomic writer instead of
  repeating the same pid-only temp-name pattern.

### Removed

- **BREAKING: `--summary-out` is gone** (#65). `.harnex/dispatch.jsonl` is now
  the only destination a dispatch writes telemetry to. Passing `--summary-out
  PATH` or `--summary-out=PATH` is rejected as an unknown flag and exits
  non-zero; it is deliberately not a silent ignore, so a stale caller fails
  immediately rather than believing it still has a second copy. 0.9.0 demoted
  the flag to an explicit-only mirror but left it in place; that mirror was the
  source of a three-times-hand-reconciled stranded-telemetry class.
- `summary_out_path` no longer appears on `dispatch_start` or `dispatch_end`
  rows, and `summary_out` no longer appears in `harnex status --json`,
  `harnex wait`, or `harnex watch` payloads. The `summary` event no longer
  carries `mirror_path`.

### Added

- **Harness-authored observed-state receipts** (#64): every dispatch now writes
  a canonical `harnex.artifact_report.v1` receipt without worker-authored JSON.
  Receipts carry explicit `receipt.author=harnex` provenance, start/end Git
  state (committed plus staged/unstaged/untracked paths and LOC), bounded Codex
  command exits, turn acceptance, and usage. The receipt is written before a
  structured `task_complete` event and refreshed with final teardown telemetry.
- Every session receives a default repo-keyed receipt under
  `~/.local/state/harnex/receipts/`; `--artifact-report` now overrides that
  destination. Live status, detached/tmux launch payloads, dispatch-start rows,
  and dispatch-end metadata expose the receipt and claims paths.
- Review workers may write a bounded optional block to
  `HARNEX_ARTIFACT_CLAIMS_PATH` (`summary`, `verdict`, and P1/P2/P3 counts).
  Claims are sanitized and copied into the receipt but never participate in
  completion acceptance or final-receipt validity.
- Receipt files and claims inputs join the existing 45-day / 1-GiB retention
  policy as a third independently configurable directory, including
  `HARNEX_RECEIPTS_MAX_AGE_DAYS` / `HARNEX_RECEIPTS_MAX_BYTES` and live/current
  path protection.

### Changed

- `TerminalStatus` resolves exclusively from the canonical stream. It
  previously preferred the mirror file named by a record's `summary_out_path`,
  which — with the writer removed — would have let a leftover mirror from an
  older release resolve status from stale data. A pre-existing mirror file on
  disk now has no effect on any id.
- `status["source"]` reports `dispatch_end` where it previously reported
  `summary_out` for rich end rows. `dispatch_history`, `dispatch_start`,
  `live`, `registry`, and `none` are unchanged.
- `artifact-report validate --final` preserves the legacy manual-v1 contract
  while recognizing the additive harness-receipt contract. Harness receipts
  validate observed acceptance and zero-delta evidence; failed exploratory
  command exits remain factual telemetry for queue policy rather than allowing
  worker claims to decide receipt validity.
- Artifact fingerprints are now internal claims-freshness bookkeeping only.
  Pre-existing, stale, malformed, or missing worker reports are overwritten by
  fresh harness proof instead of becoming work-acceptance failures. The legacy
  `init` command and `--require-artifact-report` flag remain compatible, but
  neither an explicit path nor model-authored proof is required.
- Codex autonomous completion still rejects acknowledgment-only turns as
  `completed_no_activity`; optional claims cannot satisfy the observed-activity
  gate. Receipt write/validation failure is fail-closed as `report_invalid`.
- Git observation now baselines the starting worktree so uncommitted product
  edits are included while unchanged pre-existing dirt and harness-owned
  dispatch/receipt files are excluded.

## [0.9.0] - 2026-08-03 | 01:11 AM | IST

Minor bump: the durable dispatch row family is now v2, `--summary-out` changes
from a default destination to an explicit mirror, and retention/phase policy add
operator-visible behavior.

### Added

- **Price-table cost for token-reporting adapters** (#63, plan 33
  Phase 2; subsumes #58's cost gap): new `lib/harnex/pricing.rb` holds a
  static per-1M-token USD rate table keyed by provider + model, each entry
  `as_of`-dated and hand-copied from the provider pricing pages
  (OpenAI gpt-5.x/codex and Anthropic Claude families, rates as of
  2026-08-02; update procedure documented in the file header).
  `build_summary_usage` applies it only when `cost_usd` is null, usage
  status is `observed`/`zero`, and the effective model matches the table —
  then `cost_source: "price_table"` and a new always-present
  `usage.cost_price_as_of` field record provenance. Unknown models stay
  null; provider-reported cost (Pi) is never overwritten; costs are never
  backfilled.
- The codex app-server adapter now captures the effective model from the
  schema-required `model` field on `thread/start` / `thread/resume`
  responses, so `agent.model_effective` (and price-table lookup) resolves
  without the caller passing `--meta '{"model": ...}'`.
- Token-semantics are capture-path-aware: new adapter hook
  `usage_input_includes_cached?` distinguishes codex app-server JSON
  (cached ⊆ input → billable input = input − cached) from the codex PTY
  transcript line (input excludes cached → cached prices additively).
  Verified against the captured schema fixtures and a live app-server row.
- Price-table lookup now covers Holm's effective `gpt-5.5` model and keys its
  tier-sensitive rates by the recorded service tier (`standard`, `flex`, or
  `fast`; `priority` aliases fast). Because published `gpt-5.5` rates split at
  272K active context, Harnex also requires an observed peak below that boundary;
  missing/long-context evidence remains unpriced rather than applying the wrong
  short-context rate.
- Optional repo phase policy in `.harnex/config.json`: an allowlist can `warn`
  or `reject` non-canonical effective `meta.phase` values before spawn. Explicit
  malformed policy files fail closed; no config preserves existing behavior.
- Bounded events/output retention: 45-day and 1-GiB defaults per directory,
  repo config plus environment overrides, current/live-session protection,
  oldest-first age/size pruning, one-hour automatic throttle, and bounded
  last-prune metadata. `harnex doctor` reports size/limits; `--prune --dry-run`
  previews bounded candidate paths and `--prune` applies the policy.

### Changed

- **Single tracked telemetry stream** (#63, plan 33 Phase 1): a dispatch
  now writes exactly two rows to the repo-tracked `.harnex/dispatch.jsonl`
  — the `dispatch_start` row and one unified v2 `dispatch_end` row that
  merges the thin envelope (top-level `schema_version: 2`, `record_type`,
  `id`, `status`, `tier`, timing, `tmux_state`, …) with the rich summary
  sections (`meta`, `predicted`, `actual`, `agent`, `usage`, `context`,
  `attribution`, `outcome`, `attempt`, `reliability`, `queue?`,
  `orchestration?`, artifact-report keys). Start rows stamp
  `schema_version: 2` as well. Readers accept v1 and v2 rows mixed in one
  file; `harnex history` keeps skipping pre-0.7.3 envelope-less rows.
- `--summary-out` is now an explicit-only mirror: no default path. When
  set, the identical v2 end record is appended there in addition to the
  tracked stream. Consumers that redirected `--summary-out` to keep rich
  rows should drop the flag — the tracked stream now carries everything.
  `Harnex.default_summary_out_path` is removed; every writer and reader
  resolves the stream through `DispatchHistory.path_for` (git-root walk,
  global fallback), so non-git roots stream to the global file instead of
  a repo-local `.harnex/` directory.
- The `summary` event now points `path` at the tracked stream and carries
  `mirror_path` when a mirror is configured.
- `TerminalStatus` resolves a v2 end row as both summary and history in
  one shot (branching on `record_type` first), so `wait --until done` and
  `status --id` fall back to the unified stream; legacy duck-types remain
  for pre-v2 files.
- Cross-dispatch attempt fields are harness-derived from the canonical stream:
  `attempts_total`/succeeded/failed, `fallback_triggered`, and
  `reliability.recovered` follow bounded parent links and degrade safely on
  missing, duplicate, malformed, or cyclic history. `fallback` is now a public,
  live-parent-guarded attempt kind; in-run `retry_count` remains separate.
- Public telemetry/configuration references under `docs/*.md` are now packaged
  in the gem. README, GUIDE, TECHNICAL, agent guides, and event/telemetry docs
  use the same canonical-stream, mirror, native-watch, pricing, phase-policy,
  and retention terminology.

### Fixed

- `harnex history` no longer renders blank rows for pre-0.7.3
  `{meta, predicted, actual}`-schema telemetry rows in
  `.harnex/dispatch.jsonl`: rows recognized as neither start nor end
  records are skipped in both table and `--json` output. The raw file is
  untouched — legacy rows remain available for forensics.

## [0.8.0] - 2026-08-02 | 08:46 PM | IST

Minor bump: two behavior changes below (`wait --until done` exit codes,
`--attempt-kind retry` now requiring `--parent-dispatch-id`).

### Added

- Dispatch-start records (#62): every dispatch appends a durable
  `dispatch_start` row to the repo dispatch stream at registration (id,
  session_id, pid, host, started_at, meta, schema_version); the
  `dispatch_end` row written at teardown completes it. End rows now carry
  `record_type` and `session_id` so readers can pair them.
- `harnex history` now shows uncompleted dispatches as `running` (pid alive
  on this host) or `interrupted` (pid gone, no end row) instead of hiding
  them until teardown.
- Duplicate-dispatch guard (#62): `harnex run --attempt-kind retry` requires
  `--parent-dispatch-id`, and retry/fix/superseding dispatches naming a
  still-running parent in the same repo are refused with a clear error.
  `--allow-live-parent` overrides for intentional parallelism; `review` is
  exempt.

### Changed

- `harnex wait --until done` now has a documented exit-code contract
  (guides/04_monitoring.md): `0` accepted work, `1` failed, `2` completed but
  proof rejected, `3` no such session, `124` timeout. The wrapped process's
  exit code is reported as payload data instead of being passed through.
  Payloads carry a `wait_result` field.
- `harnex wait --until done` re-checks liveness every poll (registry, then
  uncompleted start row with alive pid) and blocks while the session's pid
  is alive. Stale exit-status files and events from an earlier dispatch that
  reused the same id are ignored while a live session is in view.
- `harnex status` no longer silently reports stale registry data as live:
  rows are labelled `source: live|registry|dispatch_start` with
  `degraded: true` when the live status API was unreachable. With `--id`, a
  running session whose registry row is missing is still reported running
  from its uncompleted start row.
- One canonical repo resolution for all dispatch-stream writers and readers:
  history rows now key off the session's `repo_root` (matching the summary
  path) instead of the launch cwd, and `repo_key` canonicalizes symlinked
  paths via realpath so registries written from a symlinked cwd stay visible
  to checkers resolving the physical path.
- Refreshed the codex app-server schema fixtures against codex-cli 0.145.0
  (10 fixtures; upstream-additive changes only, no adapter impact).

## [0.7.14] - 2026-07-15 | 10:06 PM | IST

### Added

- `harnex run` now accepts opt-in orchestration metadata flags
  (`--orchestration-run-id`, `--orchestration-generation-id`,
  `--orchestration-role`, `--orchestration-session-id`, and
  `--orchestration-rotation-reason`) and emits a top-level `orchestration`
  block when present.
- New `harnex orchestration sample` / `harnex orchestration report` commands
  ingest bounded external-primary samples and compute primary-versus-worker
  queue rollups without storing prompts, transcripts, tool payloads, or secrets.
- New `harnex artifact-report init PATH` and `harnex artifact-report validate
  PATH [--final]` commands provide a bounded v1 report skeleton and
  machine-readable field diagnostics without echoing report payloads.
- `harnex run --require-artifact-report` makes fresh accepted/no-change report
  proof part of the work verdict and exposes strict mode to workers through
  `HARNEX_ARTIFACT_REPORT_REQUIRED=1`.

### Changed

- Autonomous Codex app-server turns launched with `--context` now distinguish
  provider turn completion from accepted work completion. Harnex requires
  structured command/tool activity, a Git delta, or a fresh accepted/no-change
  report before emitting `task_complete`; the classifier never parses final
  prose and applies equally to flex and fast service tiers.
- Dispatch outcomes now include additive `class` and `report_status` fields,
  and watch/wait/status/marker payloads preserve typed proof failures.

### Fixed

- Acknowledgment-only Codex turns now emit `completed_no_activity` and return a
  non-zero work/auto-stop verdict instead of being reported as successful work.
- Strict report mode fails closed for missing, malformed, unsupported,
  oversized, schema-incomplete, rejected, and unchanged stale sidecars. A valid
  explicit `no_change` report remains an accepted proof path for intentional
  no-delta work, while report-shaped JSON printed in final prose is ignored.

## [0.7.13] - 2026-07-15 | 12:24 PM | IST

### Added

- Dispatch summaries now include a stable additive `context` block with
  terminal and peak active-context pressure, source/status provenance, bounded
  sample counts, and explicit missing-sample handling. Pi RPC reports observed
  `get_session_stats.contextUsage`; Codex app-server conservatively estimates
  pressure from `tokenUsage.last` plus `modelContextWindow`; unsupported
  adapters do not fabricate values.
- Dispatch summaries now include additive `usage`, `attribution`, `outcome`, and
  per-session `attempt` blocks. `usage.status` distinguishes provider-observed,
  explicit-zero, caller-estimated, unsupported, and missing values so nullable
  cost/token fields are never mistaken for zero.
- `harnex run` accepts `--parent-dispatch-id`, `--parent-attempt-id`, and
  `--attempt-kind` (`initial`, `retry`, `fix`, `review`, or `superseding`) to
  preserve parent/child relationships while retaining separate raw effort rows.
- Terminal event streams now emit `attempt_started` / `attempt_finished` and
  translate Pi internal retry notices into `attempt_retry_scheduled`; the
  Session exposes an `attempt_fallback_switched` telemetry seam for recovery
  and fallback owners.
- Bounded artifact reports can optionally record a semantic outcome
  (`accepted`, `rejected`, `no_change`, or `unknown`). Final outcome blocks
  retain git commit/path/LOC observations without claiming they prove authorship.

### Changed

- Dispatch telemetry documentation now distinguishes cumulative usage from
  active context-window pressure and defines context sample/high-water/null
  semantics alongside usage-cost provenance, strict attribution quality,
  sidecar-backed outcomes, attempt linkage, and safe throughput/reliability
  query examples.

## [0.7.12] - 2026-07-10 | 11:19 PM | IST

### Fixed

- The new `reliability` block no longer treats legacy generic-PTY
  `exit="disconnected"` rows (process exited 0 but no adapter usage summary was
  parsed) as real transport loss. Legacy `actual.disconnections` remains
  compatible; new `reliability.real_disconnections` stays `0` for that normal
  no-summary process exit case.

## [0.7.11] - 2026-07-10 | 11:14 PM | IST

### Added

- Dispatch summaries now include top-level additive `agent` and `reliability`
  blocks for every run, and a top-level `queue` block when queue attribution is
  provided. New consumers should prefer these blocks over legacy flat fields for
  queue economics and reliability analytics.
- `harnex run` now accepts first-class queue/agent telemetry flags:
  `--project-id`, `--queue-id`, `--entry-id`, `--entry-title`, `--phase`,
  `--tier`, `--issue`, `--plan`, `--intent`, `--model`, and `--effort`.
  Explicit flags override same-named `--meta` values and are forwarded through
  tmux re-exec.
- `harnex run --require-attribution` fails before launching unless required
  queue attribution is present (`project_id`, `phase`, `intent`, and at least
  one work id).

### Changed

- Dispatch telemetry docs, README, and the packaged dispatch agents-guide now
  document queue attribution, effective agent routing fields, reliability split,
  and a sample queue grouping snippet.

## [0.7.10] - 2026-07-10 | 10:57 PM | IST

### Added

- `harnex run --artifact-report PATH` / `--validation-report PATH` now expose a
  worker-writable `harnex.artifact_report.v1` sidecar path via
  `HARNEX_ARTIFACT_REPORT_PATH` and `HARNEX_VALIDATION_REPORT_PATH`, ingest the
  report at dispatch finalization, and append compact top-level
  `artifact_report`, `validation`, and `artifacts` blocks to the dispatch
  summary row.

### Changed

- Dispatch telemetry docs, README, and the packaged dispatch agents-guide now
  document sidecar proof while keeping plain-text `koder/` artifacts canonical.

### Fixed

- Missing, malformed, unsupported-schema, and oversized artifact reports now
  fail soft with `artifact_report.ingest_status` warning telemetry instead of
  crashing or changing the wrapped process exit code.

## [0.7.9] - 2026-07-10 | 10:33 PM | IST

### Added

- `harnex run` now accepts wrapper-level `--cwd DIR` and `--root DIR` options.
  `--cwd` starts the wrapped agent in `DIR` and makes that directory the
  harnex session root for registry/session metadata and default dispatch
  summaries. `--root` changes harnex root attribution without changing the
  child process cwd.

### Changed

- `harnex run --help`, README, and the dispatch guide now document
  public-bundle / temporary-workdir dispatches with `--cwd`.
- Refreshed pinned Codex app-server schema fixtures against
  `codex-cli 0.144.1` so the release suite is green with the current local
  Codex CLI.

### Fixed

- Non-git temporary work directories no longer leak raw `git rev-parse` fatal
  messages during harnex root probing.

## [0.7.8] - 2026-06-13 | 08:45 PM | IST

### Added

- `harnex watch --id <id> --until done` now provides a native work-terminal
  watcher for existing visible/detached sessions. It exits `0` for successful
  work, non-zero for `task_failed` / failed terminal telemetry, `124` for
  wall-clock timeout, and can write optional done/fail marker files for legacy
  queue integrations.

### Changed

- Monitoring docs now recommend native `harnex watch` for unattended
  single-dispatch monitoring and reserve `harnex run --watch` for foreground
  launch-and-stall-recovery.

## [0.7.7] - 2026-06-12 | 10:48 AM | IST

### Fixed

- Codex app-server failed turns now emit `task_failed` instead of being
  misreported as successful `task_complete` work. `harnex wait --until done`
  returns non-zero for failed-turn events, dispatch history records
  `terminal_event=task_failed`, and auto-stop terminates structured sessions
  without sending a stale `turn/interrupt` after the turn is already complete.
- Codex app-server nested error notifications now preserve the real Codex error
  message (for example missing provider credentials) without counting them as
  transport disconnects.

### Changed

- Refreshed the pinned Codex app-server JSON Schema fixtures to
  `codex-cli 0.139.0` and taught the test schema validator `minLength`.

## [0.7.6] - 2026-06-09 | 12:59 AM | IST

### Added

- `harnex status --json` now exposes work-level completion fields (`done`,
  `work_state`, and `process_state`) so monitors can distinguish completed
  work from a still-live interactive process.
- `harnex wait --until done` waits for `task_complete` or terminal exit,
  whichever arrives first, giving queue monitors a safe default fence.

### Changed

- Refreshed README quick-start and monitoring guidance to emphasize
  `--context --auto-stop`, `--until task_complete` for interactive structured
  sessions, durable terminal summaries, and timeout/artifact verification.
- Monitoring, buddy, and recipe examples now gate unattended work on
  `--until done` / `done` / `work_state` instead of `state=completed` alone.

## [0.7.5] - 2026-05-26 | 05:18 PM | IST

### Added

- `Harnex::TerminalStatus` now resolves durable terminal dispatch state from
  summary/history rows so commands can classify inactive sessions without
  relying on tmp done markers.

### Changed

- `harnex status --json --id <id>` now returns a machine-readable row even when
  the live session is gone, with `state` in `running|completed|failed|unknown`
  and terminal metadata (`terminal`, `exit`, `exit_code`, `summary_out`).
- `harnex wait --id <id>` now falls back to terminal summary/history telemetry
  when registry and exit-status files are missing, returning `completed` on
  summary success and `unknown` when no durable terminal signal exists.
- Monitoring guides now treat `/tmp/*-done.txt` as legacy compatibility hints;
  canonical completion is `harnex wait` / `harnex status --json` / dispatch
  summary rows.

## [0.7.4] - 2026-05-25 | 08:45 AM | IST

### Added

- First-class `pi` structured adapter (`Harnex::Adapters::Pi`) for
  `pi --mode rpc` JSONL transport. `harnex run pi` now supports
  structured completion (`agent_end` -> `task_complete`), stop/abort,
  extension-UI dialog auto-cancel in RPC mode, streamed output/tool
  synthesis, and Pi session-stats telemetry capture.

### Changed

- Structured transport handling in `Session` now supports both Codex
  JSON-RPC (`:stdio_jsonrpc`) and Pi JSONL RPC (`:stdio_jsonl_rpc`).
- DISPATCH telemetry restores `actual.cost_usd` (adapter-reported
  approximate USD when available). Pi sessions populate it from
  `get_session_stats.cost`; adapters without reliable cost stay `null`.
- README, dispatch telemetry docs, and dispatch guide now document Pi RPC
  usage and the `--` child-flag pattern.

## [0.7.3] - 2026-05-13 | 01:43 PM | IST

### Added

- `harnex run codex --fast` now opts Codex app-server runs into
  `service_tier="fast"`. Default Codex runs now inject
  `service_tier="flex"` unless the child CLI args already supply an
  explicit `service_tier` config.
- First-class `opencode` PTY adapter. `harnex run opencode` now uses
  `Harnex::Adapters::Opencode` instead of the generic fallback, with
  an OpenCode-specific stop sequence (double Ctrl+C), repo path
  inference (`--dir` or positional project path), and session-id
  extraction from transcript tails (`Continue opencode -s ...`).

### Changed

- `harnex run` now rejects unknown long flags before spawning the
  agent process, with a clear error pointing at `harnex run --help`.
  Anything past the `--` separator continues to forward unchanged
  to the agent CLI. Closes the trigger that correlated with the F23
  auto-stop teardown leak. Closes harnex issue #38.
- Codex app-server contract fixtures are refreshed against
  `codex-cli 0.130.0`; response builders now include the required
  `thread.sessionId` field.
- Internal Codex app-server code now has the extracted
  `Harnex::Codex::AppServer::Client` namespace and the subprocess
  restart primitive needed by the deployment-fallback plan. No
  public fallback CLI flag is exposed yet.

### Fixed

- `harnex run` now defaults dispatch summaries to
  `<repo>/.harnex/dispatch.jsonl` for every resolved repo, regardless
  of whether a legacy `koder/` directory exists. Closes harnex issue
  #39.
- `harnex run` with `--auto-stop` now exits within a bounded grace
  (default 5s, override via `HARNEX_AUTOSTOP_TEARDOWN_GRACE_SECONDS`)
  after `task_complete`. Closes a leak where the wrapping Ruby parent
  process could sleep on `futex_wait_queue` indefinitely during
  teardown, surviving as `orphan_tmux` until manually swept (F09
  detected; F23 remediates). Closes harnex issue #37.

## [0.7.2] - 2026-05-08

### Fixed

- `harnex run` now resolves the repo-local
  `<repo>/.harnex/dispatch.jsonl` write path from the supervisor's
  launch cwd (captured at invocation time), not from the agent's
  runtime cwd. Closes a regression where cross-repo dispatches
  (supervisor in repo A, agent `cd`'s into repo B) wrote their
  terminal row only to the global fallback, never to repo A.

### Added

- `harnex doctor --sweep` reports read-only harnex/tmux session drift,
  including active registry rows, matching `cx-*` tmux windows, orphan
  tmux windows, and stale session log files whose owning pid is gone.

## [0.7.1] - 2026-05-08

### Fixed

- `harnex run --auto-stop` now observes the terminal `task_complete`
  event after the agent subprocess exits before tearing down, closing
  a race where one-shot dispatches could report `timeout` even when
  the agent finished the task cleanly. Adds a regression test that
  exercises the post-exit event drain path.

- `harnex wait` predicates now classify dispatch progress by
  structured event-record fields instead of regex-matching the
  human-readable transcript, with the prior exact-marker text as a
  legacy fallback. Eliminates a class of spurious matches where
  prose containing a marker word was misread as a state transition.

### Added

- Dispatch summaries now preserve declared brief budget metadata
  (`read_budget_lines`, `output_ceiling_lines`) from `--meta` and
  record rough terminal measurements (`lines_changed`, `output_lines`,
  `output_bytes`, `event_records`) for downstream budget enforcement.

## [0.7.0] - 2026-05-08

### Added

- `harnex run` now appends one terminal dispatch record to
  `<repo>/.harnex/dispatch.jsonl`, falling back to
  `~/.local/state/harnex/dispatch.jsonl` outside git repos. New
  `harnex history` reads that log with `--limit`, `--since`, `--id`,
  `--global`, `--json`, and `--all` filters.
- DISPATCH row `actual` now includes `turn_count`, `tool_calls`,
  `commands_executed`, `rate_limits`, `output_log_path`, and
  `events_log_path` — surfacing data harnex already tracked but did
  not persist. `meta.parent_dispatch_id` now auto-derives from
  `$HARNEX_ID` when not supplied via `--meta`. (#35 Tier 2)
- DISPATCH row `meta.agent_provider` and `meta.agent_version` now
  populated. `provider` is a per-adapter constant
  (claude → `anthropic`, codex → `openai`, generic → nil).
  `agent_version` lazily probes `<base_command.first> --version`
  with a 2s timeout, memoizes per adapter, and falls back to nil if
  the binary is missing or stalls. (#35 Tier 3)

### Removed

- DISPATCH row dropped four always-null fields with no code path
  populating them: `actual.cost_usd`, `actual.tests_run`,
  `actual.tests_passed`, `actual.tests_failed`, and
  `meta.agent_deployment`. Cost computation belongs to downstream
  consumers (per-model rate tables change frequently); test-result
  aggregation belongs to CI integrations, not the harness; and the
  `agent_deployment` concept had no source of truth. JSON Lines
  consumers should update column readers — schema is now stable but
  smaller. (#35 Tier 3)

### Fixed

- `harnex wait` (default exit-watch mode) now blocks until the
  exit-status file is on disk after the agent subprocess dies, with
  a 5s grace bound (override via `HARNEX_EXIT_STATUS_GRACE_SECONDS`).
  The exit-status file is written *after* the DISPATCH row in the
  parent's teardown ensure block, so its presence guarantees the row
  is on disk. Closes the race where `wait` could return between
  `Process.wait2` unblocking and `Session#finalize_session!`
  appending the row, which made dispatch-poll orchestrators flake
  on "missing telemetry". (#36)

### Changed

- `koder/STATE.md` is now a thin past / present / future handoff
  instead of a long-running project history. Durable change history
  belongs in `CHANGELOG.md`, release verification in `koder/releases/`,
  and issue or implementation detail in `koder/issues/` or
  `koder/plans/`.
- Agent orientation and the repo-local `open` / `close` skills now
  explicitly tell future sessions to keep `STATE.md` concise and route
  detailed notes to the durable tracking document that owns them.

## [0.6.5] — 2026-05-07

### Added

- `harnex run --auto-stop` for one-shot `--context` dispatches.
  JSON-RPC Codex sessions stop after the first `task_complete` event,
  while PTY-backed sessions stop after the initial context turn returns
  to a prompt. The shutdown path reuses `harnex stop`, including the
  JSON-RPC TERM/KILL fallback.

### Fixed

- JSON-RPC Codex sessions now terminate their `codex app-server`
  subprocess on `harnex stop`: harnex preserves the existing
  `turn/interrupt` request, then sends TERM with a bounded KILL
  fallback so the runner can release the API port and registry entry.
- JSON-RPC adapter now captures token usage in `DISPATCH.jsonl`.
  `Session#handle_rpc_notification` reads schema-true
  `params["tokenUsage"]` on `thread/tokenUsage/updated`, and the
  session-end telemetry path branches on `adapter.transport`: JSON-RPC
  pulls the cumulative `tokenUsage.total` and maps the camelCase
  `{input,output,cachedInput,reasoningOutput}Tokens` fields onto the
  snake_case `actual.*_tokens` columns. PTY continues to scrape the
  transcript tail. (#33)
- JSON-RPC adapter rejects `-m`/`--model`/`--model=…` early with a
  clear `ArgumentError` pointing at `-c model="<name>"`. Previously the
  flag was silently forwarded to `codex app-server`, which exited at
  startup and surfaced only as an opaque `disconnected` transport
  message. Legacy PTY adapter (`--legacy-pty`) still accepts `-m`.
  `harnex help run` and `guides/01_dispatch.md` document the JSON-RPC
  vs PTY flag-form difference. (#34)

## [0.6.4] — 2026-05-06

### Fixed

- JSON-RPC adapter (`codex app-server`): harnex now mediates Codex's
  server-to-client approval requests via the protocol — auto-approves
  `applyPatchApproval`, `execCommandApproval`,
  `item/commandExecution/requestApproval`, and
  `item/fileChange/requestApproval`. Previously the adapter rejected
  every server-side request with `-32601 "Unsupported server request"`,
  which meant Codex's default sandbox blocked shell exec, file changes,
  git commits, and package-manager invocations whenever a dispatched
  worker tried to do real work. Autonomous worker dispatches now run
  cleanly under the default sandbox without needing
  `--dangerously-bypass-approvals-and-sandbox` or
  `-c sandbox_mode=danger-full-access`.
- `CodexAppServer#build_command` now appends operator-supplied codex
  flags (passed via `harnex run codex -- -c key=value`) while still
  filtering out the harnex-context entry that `--context` smuggles
  through `@extra_args` (codex `app-server` rejects positional input).

### Changed

- `--legacy-pty` is now a long-term supported fallback rather than a
  deprecated path. The 0.7.0-removal plan is dropped — the legacy PTY
  adapter remains the right tool for interactive/TUI use cases and for
  any operator who prefers terminal-native Codex chrome. JSON-RPC
  remains the default for autonomous worker dispatches and structured
  observability.

### Added

- JSON-RPC adapter: classify sub-5s pre-turn exits as `boot_failure`
  (vs the existing `disconnected` terminal state), tracked by latching
  on `turn/started`. `build_summary_actual` counts `boot_failure` exits
  in `actual.disconnections` so early-boot deaths are not lost from
  dispatch telemetry. First of three planned commits for issue #32;
  remaining work (ensure-block telemetry write + optional `last_error`
  capture) tracked separately.

## [0.6.3] — 2026-05-06

### Fixed

- JSON-RPC adapter (`codex app-server`): `--context` boot injection now
  succeeds against real Codex CLI. Three schema mismatches in
  `Adapters::CodexAppServer` caused 100% session disconnect on boot
  with `"Invalid request: invalid type: null, expected a string"`:
  - `ensure_thread!` and the `thread/started` notification handler read
    `result["threadId"]`, but Codex's actual `thread/start` response is
    `{"thread": {"id": "..."}}`. With `@thread_id = nil`, the subsequent
    `turn/start` sent `threadId: null` and Codex's serde rejected it.
  - `dispatch` sent `input: { content: [{type, text}] }`, but
    `TurnStartParams.input` is an **array** of `UserInput`. Now sends
    `input: [{type: "text", text: "..."}]`.
  - `initialize` joined ALL `extra_args` into `@initial_prompt`, which
    prepended Codex CLI flags (e.g. `-m gpt-5.5-mini -c
    model_reasoning_effort=low`) into the prompt content. Now extracts
    only the harnex-prefixed context element.

  Re-opens and properly closes #29. The 0.6.2 fix shipped clean tests
  but the test stubs mirrored harnex's wrong assumptions instead of
  Codex's actual JSON-RPC schema, so production was 100% broken on the
  default JSON-RPC path.

### Notes

- Test stubs in `codex_appserver_lifecycle_test.rb` and
  `session_jsonrpc_test.rb` still mirror harnex's old assumptions.
  Tracked as a follow-up (test rewrite using `codex app-server
  generate-json-schema` as the source of truth, plus a contract-test
  gate). Existing tests remain green; the structural improvement does
  not block this release.
- `--legacy-pty` remains as the documented fallback. Removal still
  scheduled for 0.7.0 once test-rewrite + contract gate land.

## [0.6.2] — 2026-05-06

### Fixed

- App-server adapter: `--context` delivery and `harnex send` mid-session
  now succeed without `--legacy-pty`. Previously both raised
  `NotImplementedError` from `build_send_payload` on the stdio_jsonrpc
  transport — `--context` boot fired a `disconnected source=transport`
  event and the session never registered; `harnex send` timed out at
  120s with `delivery timed out`. Closes #29.

### Notes

- `--legacy-pty` is no longer required for any normal dispatch flow.
  Removal still scheduled for 0.7.0 per the 0.6.1 deprecation note.

## [0.6.1] — 2026-05-06

### Added

- `harnex agents-guide [topic]` exposes dispatch, chain, buddy,
  monitoring, and naming guidance from the installed CLI.
- `harnex --help` now points agents to `harnex agents-guide`.
- `harnex help <command>` entries now include common patterns and gotchas for
  agent dispatch workflows.

### Removed

- `harnex skills install` and `harnex skills uninstall`.
- Bundled `skills/` sources and repo-local skill symlinks. Agents now discover
  guidance through `harnex --help` and `harnex agents-guide`.

### Notes

- `--legacy-pty` removal is still scheduled for 0.7.0.
- `man harnex` was deferred; the CLI-native `agents-guide` path satisfies the
  agent-discovery acceptance test without adding a man-page build dependency.

## 0.6.0 — 2026-05-06

### Architectural pivot: Codex on JSON-RPC

harnex now speaks `codex app-server` JSON-RPC over stdio for the
Codex adapter. Pane-scraping is retired for Codex. Closed by
construction:

- #22 (Codex side; `--watch --stall-after` still applies to
  claude/generic)
- #24 (disconnect detection — `error` notifications and JSON-RPC
  error responses replace screen-text regex)
- #25 (first-class completion signal — `turn/completed` is it)

### New

- `harnex wait --until task_complete` — block until a turn completes.
  Example: `harnex wait --id cx-i-242 --until task_complete`.
  Adapter-agnostic; tails the events JSONL.
- `harnex status --json` includes `last_completed_at`, `model`,
  `effort`, `auto_disconnects`.
- `harnex doctor` preflight checks Codex CLI ≥ 0.128.0.
- `Adapter#transport` and `Adapter#describe` extension points so
  callers can introspect adapter contracts. Default is
  `:pty` for backward compatibility.

### Migration

- Codex CLI ≥ 0.128.0 required.
- Existing `harnex run codex ...` invocations work unchanged.
- Emergency fallback: `harnex run codex --legacy-pty ...` (the
  pre-0.6.0 PTY adapter). Deprecated; will be removed in 0.7.0.

### Cross-repo

- Resolves holm #201 from the harnex side. holm #271 (substrate v2
  meta) tracks the broader pivot.

## 0.5.0 — 2026-05-01

### Added

- `harnex run --meta '<JSON>'` — per-dispatch metadata intake captured into
  the `started` event for downstream telemetry analysis.
- `harnex run --summary-out PATH` — appends one consolidated dispatch
  telemetry record per session (`meta` + `predicted` + `actual` blocks) to
  a project-local file. Default target is `<repo>/koder/DISPATCH.jsonl`.
- Token usage + git telemetry capture: new `usage`, `git`, and `summary`
  events emitted on session end with input/output/reasoning/cached tokens,
  wall time, cost, LOC changed, files changed, and commits made.

### Notes

- Closes #23 (dispatch telemetry capture). Additive — `events`
  `schema_version` stays at `1`.
- Authoritative DISPATCH record schema is maintained in the consumer
  project (holm `koder/DISPATCH.schema.md`); harnex implements what is
  required and leaves non-extractable fields explicitly `null`.

## 0.4.0 — 2026-04-30

### Added — Built-in dispatch monitoring (#22, Layers 1–4)

- **Layer 1**: `log_mtime` and `log_idle_s` exposed in `harnex status`
  payloads, with an `IDLE` column in text mode.
- **Layer 2**: `harnex run --watch --stall-after DUR --max-resumes N`
  blocking babysitter for fire-and-watch workflows. Auto-resumes a
  stalled session up to `N` times. Legacy file-hook mode preserved via
  the renamed `--watch-file` flag.
- **Layer 3**: `harnex run --preset impl|plan|gate` resolves
  stall/resume defaults; explicit `--stall-after` / `--max-resumes`
  flags still override.
- **Layer 4**: `harnex events --id <session>` JSONL stream with v1
  schema (envelope: `schema_version`, `seq`, `ts`, `id`, `type`); emits
  `started`, `send`, `exited` events. `send.msg` truncated to 200 chars
  with `msg_truncated` flag. File transport at
  `~/.local/state/harnex/events/<repo>--<id>.jsonl`. Stability promise:
  `schema_version: 1` means additive-only changes.

### Notes

- Layer 5 (codex stream-disconnect detection) was deferred at 0.4.0
  close to avoid regex-heuristic stalls. Later closed by construction
  in 0.6.0 via the Codex app-server adapter (#24, #27).

## 0.3.4 — 2026-04-24

### Changed

- Skill catalogue collapsed: `harnex` orchestrator skill merged into
  `dispatch`; `chain-implement` rewritten as a cohesive set;
  cross-references audited end-to-end. Closes #21.

### Notes

- The bundled skills system was later removed entirely in 0.6.1
  (superseded by CLI-discoverable `harnex agents-guide`).

## 0.3.3 — 2026-04-23

### Fixed

- `--tmux` no longer greedily consumes the next flag as the window
  name. Previously `harnex run codex --tmux --id foo` was parsed as
  `--tmux="--id"`, dropping the explicit session ID. Closes #20.

## 0.3.2 — 2026-04-19

### Fixed

- State detection for cursor-addressed TUIs (Codex v0.121+). The
  cursor-positioning escape sequences emitted by newer Codex versions
  were confusing the prompt detector, leaving sessions stuck in
  `unknown` state.
