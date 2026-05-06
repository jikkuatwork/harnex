# Changelog

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
