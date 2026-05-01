# Dispatch Telemetry

`harnex run` can capture predicted-vs-actual dispatch telemetry for a wrapped
agent session. The raw measurements are emitted on the v1 events stream, and a
consolidated JSONL summary can be appended for downstream analysis.

## CLI flags

```text
harnex run codex --meta '{"model":"gpt-5.3-codex","effort":"high","predicted":{"input_tokens":[200000,800000]}}'
harnex run codex --summary-out koder/DISPATCH.jsonl
```

- `--meta JSON` must be a JSON object. The parsed object is echoed verbatim on
  the `started.meta` event.
- `--summary-out PATH` writes one consolidated JSON line per dispatch to
  `PATH`.
- If `--summary-out` is omitted and `<repo>/koder/` exists, harnex writes to
  `<repo>/koder/DISPATCH.jsonl`.
- If no summary path resolves, harnex still emits `usage` and `summary` events;
  the `summary.path` value is `null` and no summary file is written.

## Metadata and prediction contract

The consolidated record has `meta`, `predicted`, and `actual` blocks.

Harnex-owned `meta` fields are always populated when derivable: `id`,
`tmux_session`, `started_at`, `ended_at`, `harness`, `harness_version`,
`agent`, `host`, `platform`, `repo`, `branch`, `start_sha`, and `end_sha`.
`description` comes from `--description` when set.

These top-level `--meta` keys pass through into `meta` when provided:
`orchestrator`, `orchestrator_session`, `chain_id`, `parent_dispatch_id`,
`tier`, `phase`, `issue`, `plan`, and `task_brief`. Unknown top-level keys are
kept on `started.meta` but are not copied into the consolidated record.

`predicted` is copied verbatim from `--meta.predicted` when it is a JSON object;
otherwise it is `{}`. Harnex does no profile lookup or recommendation-table
resolution.

## Actuals

At process exit, harnex reads the last 16 KB of the transcript and asks the
adapter to parse a session summary. The Codex adapter currently extracts token
counts and `agent_session_id`; adapters without a parser emit nullable usage
fields.

Git actuals are captured with `git rev-parse`, `git diff --shortstat`, and
`git rev-list --count` between the start and end SHAs. Git failures leave the
corresponding consolidated fields `null` and omit `git` events.

`actual.cost_usd` is always `null` in harnex. Consumers compute cost downstream
with their own pricing tables.

`actual.tests_run`, `actual.tests_passed`, and `actual.tests_failed` are always
`null` in this version; harnex does not detect test runs.

## Exit taxonomy

- `success`: wrapped process exited `0` and a session summary was parsed.
- `failure`: wrapped process exited non-zero.
- `timeout`: wrapped process exited with code `124`.
- `disconnected`: wrapped process exited `0` but no session summary was parsed.

Summary file writes are best-effort. Write failures are printed as warnings and
do not change the wrapped process exit code.
