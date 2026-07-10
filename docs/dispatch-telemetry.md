# Dispatch Telemetry

`harnex run` captures predicted-vs-actual dispatch telemetry for a wrapped
agent session. Raw measurements are emitted on the v1 events stream, and a
consolidated JSONL summary is appended for downstream analysis.

Every completed run also appends one compact dispatch-history record. In a git
repo, `harnex history` reads `<repo>/.harnex/dispatch.jsonl`; outside a git repo
it reads `~/.local/state/harnex/dispatch.jsonl`.

## CLI flags

```text
harnex run codex --meta '{"model":"gpt-5.3-codex","effort":"high","predicted":{"input_tokens":[200000,800000]}}'
harnex run codex --summary-out tmp/dispatch-summary.jsonl
harnex run pi --artifact-report .harnex/reports/pi-i-52.json --context 'Write proof to $HARNEX_ARTIFACT_REPORT_PATH'
```

- `--meta JSON` must be a JSON object. The parsed object is echoed verbatim on
  the `started.meta` event.
- `--summary-out PATH` writes the consolidated summary JSON line to `PATH`.
- `--artifact-report PATH` asks the worker to write a bounded
  `harnex.artifact_report.v1` JSON sidecar. Harnex exposes the absolute path as
  `HARNEX_ARTIFACT_REPORT_PATH` and ingests it at finalization.
- `--validation-report PATH` is an alias for `--artifact-report` and also makes
  the same path available as `HARNEX_VALIDATION_REPORT_PATH` for worker prompts
  that only need validation proof.
- If `--summary-out` is omitted and harnex has a non-empty resolved repo root,
  the summary path defaults to `<repo>/.harnex/dispatch.jsonl`, regardless of
  whether the repo has a legacy `koder/` directory.
- The compact history record is appended after the consolidated summary record.
  In the common git-repo default, both records are written to
  `<repo>/.harnex/dispatch.jsonl`; the compact record is the record intended for
  `harnex history`.

Use `harnex history --json | jq .` for pipelines over the repo-local log.

## Metadata and prediction contract

The consolidated record always has `meta`, `predicted`, and `actual` blocks.
When `--artifact-report` / `--validation-report` is configured, harnex may also
add `artifact_report`, `validation`, and `artifacts` top-level blocks.

Harnex-owned `meta` fields are always populated when derivable: `id`,
`tmux_session`, `description`, `started_at`, `ended_at`, `harness`,
`harness_version`, `agent`, `agent_version`, `agent_provider`, `host`,
`platform`, `repo`, `branch`, `start_sha`, and `end_sha`.

These top-level `--meta` keys pass through into `meta` when provided:
`orchestrator`, `orchestrator_session`, `chain_id`, `parent_dispatch_id`,
`tier`, `phase`, `issue`, `plan`, and `task_brief`. Unknown top-level keys are
kept on `started.meta` but are not copied into the consolidated record.

`predicted` is copied verbatim from `--meta.predicted` when it is a JSON object;
otherwise it is `{}`. Harnex does no profile lookup or recommendation-table
resolution.

## Artifact and validation sidecars

The artifact report sidecar is deliberately small and links machine-readable
proof to canonical human-readable artifacts (usually files under `koder/`). A
valid v1 report looks like:

```json
{
  "schema": "harnex.artifact_report.v1",
  "status": "pass",
  "canonical_artifacts": ["koder/issues/52_typed_artifact_validation_sidecars.md"],
  "validation": {
    "status": "pass",
    "final_reported": true,
    "commands": [
      { "cmd": "ruby -Ilib -Itest -e 'Dir[\"test/**/*_test.rb\"].each { |f| require_relative f }'", "exit_code": 0 }
    ]
  },
  "artifacts": [
    {
      "type": "gate",
      "summary": "Full suite passed.",
      "evidence": ["495 runs, 1708 assertions, 0 failures"],
      "confidence": 1.0,
      "canonical_ref": "koder/issues/52_typed_artifact_validation_sidecars.md"
    }
  ]
}
```

At finalization, harnex reads at most 256 KiB from the report path. Valid
reports add compact `validation` and `artifacts` blocks to the dispatch row. The
`artifact_report` block always records the sidecar `path`, `bytes`, `sha256`,
`schema`, and `ingest_status` when a path was configured. Missing, malformed,
unsupported-schema, and oversized reports fail soft with
`artifact_report.ingest_status` plus `artifact_report.warning`; the wrapped
process exit code is not changed.

Harnex does not copy large transcripts or replace plain-text `koder/` docs. The
sidecar is an evidence index for queue tooling; the canonical explanation should
remain in the referenced files.

## Actuals

At process exit, harnex collects usage through the active adapter. JSON-RPC
Codex sessions read cumulative `thread/tokenUsage/updated` data, Pi RPC sessions
read `get_session_stats`, and PTY adapters parse the last 16 KB of transcript
when they support a parser. Adapters without a parser emit nullable usage
fields.

Git actuals are captured with `git rev-parse`, `git diff --shortstat`, and
`git rev-list --count` between the start and end SHAs. Git failures leave the
corresponding consolidated fields `null` and omit `git` events.

The `actual` block includes model/effort hints from `--meta`, duration, token
counts, `agent_session_id`, `cost_usd`, adapter transport, git deltas, exit
reason, task completion state, signal/exit code, last error, operational
counters (`stalls`, `force_resumes`, `disconnections`, `compactions`,
`turn_count`, `tool_calls`, `commands_executed`), rate-limit payloads,
output/event volume measurements, and output/events log paths.

`cost_usd` is adapter/provider-reported approximate USD cost when the adapter
has a reliable structured source (for example Pi RPC `get_session_stats.cost`);
it remains `null` for adapters without reliable cost telemetry.

## Exit taxonomy

- `success`: wrapped process exited `0` and a session summary was parsed.
- `failure`: wrapped process exited non-zero.
- `timeout`: wrapped process exited with code `124`.
- `boot_failure`: JSON-RPC app-server exited within the startup window before a
  turn was observed.
- `disconnected`: wrapped process exited `0` but no session summary was parsed.

Summary file writes are best-effort. Write failures are printed as warnings and
do not change the wrapped process exit code.
