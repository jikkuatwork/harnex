# Changelog

## [Unreleased]

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
