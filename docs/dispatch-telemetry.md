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
harnex run pi --project-id harnex --queue-id queue-005 --entry-id SP-4 --phase implement --intent queue-work --require-attribution
harnex run pi --orchestration-run-id queue-005 --orchestration-generation-id gen-1 --orchestration-role worker
harnex orchestration report --dispatch .harnex/dispatch.jsonl --run-id queue-005 --json
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
- `--project-id`, `--queue-id`, `--entry-id`, `--entry-title`, `--phase`,
  `--tier`, `--issue`, `--plan`, `--intent`, `--model`, `--effort`,
  `--parent-dispatch-id`, `--parent-attempt-id`, and `--attempt-kind` are
  first-class queue/agent telemetry flags. They are persisted as caller-provided
  strings and override same-named `--meta` values. `--attempt-kind` is one of
  `initial`, `retry`, `fix`, `review`, or `superseding`; linkage fields keep
  independently-run follow-ups joinable without merging their raw usage.
- `--orchestration-run-id`, `--orchestration-generation-id`,
  `--orchestration-role`, `--orchestration-session-id`, and
  `--orchestration-rotation-reason` opt a dispatch row into logical
  primary-orchestrator rollups. `--orchestration-role` is `primary` or
  `worker`; Harnex-managed primaries should use `primary` instead of emitting a
  duplicate external sample for the same usage row.
- `--require-attribution` fails before launch unless `project_id`, `phase`,
  `intent`, and at least one of `queue_id` / `entry_id` / `issue` / `plan` are
  present through first-class flags or `--meta`.
- If `--summary-out` is omitted and harnex has a non-empty resolved repo root,
  the summary path defaults to `<repo>/.harnex/dispatch.jsonl`, regardless of
  whether the repo has a legacy `koder/` directory.
- The compact history record is appended after the consolidated summary record.
  In the common git-repo default, both records are written to
  `<repo>/.harnex/dispatch.jsonl`; the compact record is the record intended for
  `harnex history`.

Use `harnex history --json | jq .` for pipelines over the repo-local log.

## Metadata and prediction contract

The consolidated record always has `meta`, `predicted`, `actual`, `agent`,
`usage`, `context`, `attribution`, `outcome`, `attempt`, and `reliability`
blocks. When queue attribution fields are provided, harnex also adds a
top-level `queue` block. When orchestration fields are provided, harnex adds a
top-level `orchestration` block. When `--artifact-report` /
`--validation-report` is configured, harnex may also add `artifact_report`,
`validation`, and `artifacts` top-level blocks.

Harnex-owned `meta` fields are always populated when derivable: `id`,
`tmux_session`, `description`, `started_at`, `ended_at`, `harness`,
`harness_version`, `agent`, `agent_version`, `agent_provider`, `host`,
`platform`, `repo`, `branch`, `start_sha`, and `end_sha`.

These top-level `--meta` keys pass through into `meta` when provided:
`orchestrator`, `orchestrator_session`, `chain_id`, `parent_dispatch_id`,
`parent_attempt_id`, `attempt_kind`, `tier`, `phase`, `issue`, `plan`, and
`task_brief`. Queue-specific keys such as
`project_id`, `queue_id`, `entry_id`, `entry_title`, and `intent` are used for
the top-level `queue` block but are not duplicated into legacy `meta`. Unknown
top-level keys are kept on `started.meta` but are not copied into the
consolidated record.

`predicted` is copied verbatim from `--meta.predicted` when it is a JSON object;
otherwise it is `{}`. Harnex does no profile lookup or recommendation-table
resolution.

## Queue, agent, and reliability blocks

The top-level `queue` block is emitted only when at least one queue attribution
field is known. When present, it has a stable key set and preserves values as
strings:

```json
{
  "queue": {
    "project_id": "harnex",
    "queue_id": "queue-005",
    "entry_id": "SP-4",
    "entry_title": "Implement sidecar ingestion",
    "issue": "52",
    "plan": "52",
    "phase": "implement",
    "tier": "B",
    "intent": "queue-work"
  }
}
```

The top-level `agent` block is always emitted and is the preferred home for
routing details; legacy `meta.agent*` and `actual.model` stay for compatibility:

```json
{
  "agent": {
    "cli": "codex",
    "provider": "openai",
    "model_requested": "gpt-5.3-codex",
    "model_effective": "gpt-5.3-codex",
    "reasoning_effort": "high",
    "service_tier": "flex",
    "adapter_transport": "stdio_jsonrpc"
  }
}
```

The top-level `reliability` block is always emitted and should be preferred over
legacy `actual.disconnections` for reliability analytics:

```json
{
  "reliability": {
    "adapter_close": "normal",
    "real_disconnections": 0,
    "stream_interruptions": 0,
    "stalls": 0,
    "force_resumes": 0,
    "compactions": 0,
    "recovered": false
  }
}
```

`adapter_close` is `normal` for ordinary process/adapter completion,
`interrupted` for timeout/signal termination, `lost` for boot failure or real
transport loss, and `unknown` when harnex cannot classify it. Successful
structured runs that close normally after task completion should report
`real_disconnections: 0` even if old consumers still read the legacy counter.

Example grouping for queue analysis:

```bash
jq -r 'select(.queue) | [.queue.project_id, .queue.queue_id, .queue.entry_id, .queue.phase, .agent.model_effective] | @tsv' .harnex/dispatch.jsonl
```

## Usage, context pressure, attribution, outcomes, and attempts

`usage` makes nullable legacy `actual` token and cost fields interpretable:

```json
{
  "usage": {
    "status": "observed",
    "cost_usd": 1.42,
    "cost_source": "provider_reported",
    "input_tokens": 120000,
    "output_tokens": 8000,
    "cached_input_tokens": 2000,
    "reasoning_tokens": null,
    "total_tokens": 130000
  }
}
```

`usage.status` is `observed` for an adapter measurement, `zero` for an explicit
all-zero adapter measurement, `estimated` for caller-supplied
`--meta '{"usage":{"status":"estimated",...}}'` values, `unsupported` when
the adapter has no supported usage source, or `missing` when a supported source
provided no observation. `cost_source` is `provider_reported` only for a
reliable adapter value and `caller_estimate` for an estimate. `null` never means
zero, and provider-reported cost is approximate telemetry, not a billing
invoice.

`context` is separate from cumulative `usage`: it describes how full the active
model context became, not how many tokens all requests accumulated:

```json
{
  "context": {
    "status": "observed",
    "source": "pi_get_session_stats",
    "terminal_tokens": 64000,
    "window_tokens": 200000,
    "terminal_percent": 32.0,
    "peak_tokens": 118000,
    "peak_percent": 59.0,
    "samples": 7,
    "missing_samples": 1,
    "latest_sample_status": "missing"
  }
}
```

`terminal_*` is the final **valid** occupancy sample and `peak_*` is the
independent high-water mark across valid samples. `window_tokens` is the model
window paired with that terminal sample. `samples` counts bounded source
samples, including unavailable ones; `missing_samples` counts that unavailable
subset. Consequently, a null sample immediately after compaction leaves the
last valid terminal and peak values intact while setting
`latest_sample_status: "missing"`. Null never means zero.

`context.status` is `observed` for Pi's dedicated
`get_session_stats.contextUsage` signal, `estimated` for Codex app-server,
`missing` when a supported source yielded no valid occupancy, or `unsupported`
when the adapter has no active-context source. `source` is
`pi_get_session_stats` or `codex_thread_token_usage_last` for those structured
adapters and is null for unsupported adapters. Pi's percentage is adapter
reported. Codex's `tokenUsage.last.totalTokens` is the latest model-reported
active context size, but it excludes local items appended after that response;
Harnex therefore labels it estimated and derives
`terminal_percent = last.totalTokens / modelContextWindow * 100`. That is
full-window pressure, not Codex TUI's baseline-adjusted “context left” display.
No prompt, transcript, message, tool payload, or compaction summary is copied
into this block.

`attribution.status` is `complete` when `project_id`, `phase`, `intent`, and a
work id are present; `partial` when any attribution is known but that contract
is incomplete; otherwise `missing`. `outcome` keeps git observations separate
from semantic acceptance: its `status` is `accepted`, `rejected`, `no_change`,
or `unknown`; only a worker sidecar can assert accepted/rejected. The block also
contains final commit/path/LOC observations and does **not** claim those changes
prove authorship.

Every row has one Harnex-session `attempt`. Its random `id` is distinct from
operator-visible `run_id`; `parent_attempt_id` and `parent_dispatch_id` link
retries/fixes/reviews while each row keeps separate raw token and cost values.
The events JSONL adds `attempt_started` and `attempt_finished`. Adapters that
report an internal retry additionally emit `attempt_retry_scheduled`; future
recovery/fallback owners can emit `attempt_fallback_switched` without changing
the row schema.

## Orchestration tax rollups

`harnex orchestration` joins one logical primary-orchestrator run across
primary generations and child dispatches. It is opt-in and bounded: the sample
path stores counters and lifecycle labels only.

Harnex-managed primaries can be represented directly by their dispatch row:

```bash
harnex run pi --orchestration-run-id queue-005 \
  --orchestration-generation-id primary-1 --orchestration-role primary ...
```

External interactive primaries can emit bounded samples through an integration
or shell command:

```bash
harnex orchestration sample --out .harnex/orchestrator.jsonl \
  --run-id queue-005 --generation-id primary-1 --project-id harnex \
  --queue-id queue-005 --session-id pi-primary-1 \
  --context-status observed --context-tokens 64000 \
  --context-window-tokens 200000 --context-percent 32 \
  --usage-status observed --usage-input-tokens 120000 \
  --usage-output-tokens 9000 --usage-total-tokens 129000 \
  --tool-calls 31 --compactions 1
```

The sample schema is `harnex.orchestrator_sample.v1`. Valid sample events are
`sample`, `generation_started`, `generation_finished`, `rotation`, `recovery`,
and `compaction`. Samples must never include prompts, transcripts, hidden
reasoning, tool arguments/results, secrets, or private payloads.

Reports join dispatch rows whose `orchestration.run_id` matches the requested
run and optional external samples with the same `orchestration_run_id`:

```bash
harnex orchestration report --dispatch .harnex/dispatch.jsonl \
  --samples .harnex/orchestrator.jsonl --run-id queue-005 --json
```

The report schema is `harnex.orchestration_tax.v1`. It includes primary usage
and context coverage, per-generation peaks and rotation reasons, worker usage,
accepted/rejected/blocked/unknown child outcomes deduplicated by work id,
primary usage/tool calls per accepted entry, and explicit `missing` /
`unsupported` statuses instead of treating absent telemetry as zero.

## Artifact and validation sidecars

The artifact report sidecar is deliberately small and links machine-readable
proof to canonical human-readable artifacts (usually files under `koder/`). A
valid v1 report looks like:

```json
{
  "schema": "harnex.artifact_report.v1",
  "status": "pass",
  "outcome": {
    "status": "accepted",
    "summary": "Queue gate accepted the implementation."
  },
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
reports add compact `validation` and `artifacts` blocks to the dispatch row. A
valid optional `outcome.status` (`accepted`, `rejected`, `no_change`, or
`unknown`) is copied into the top-level outcome evidence; it is the only source
that can assert semantic acceptance or rejection. The `artifact_report` block
always records the sidecar `path`, `bytes`, `sha256`,
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
fields. Separately, Pi aggregates bounded `contextUsage` samples and Codex
aggregates `tokenUsage.last` plus `modelContextWindow`; neither source is
substituted with cumulative usage when active occupancy is unavailable.

Git actuals are captured with `git rev-parse`, `git diff --shortstat`, and
`git rev-list --count` between the start and end SHAs. Git failures leave the
corresponding consolidated fields `null` and omit `git` events.

The `actual` block includes model/effort hints from `--meta`, duration, token
counts, `agent_session_id`, compatibility `cost_usd`, adapter transport, git
deltas, exit reason, task completion state, signal/exit code, last error,
operational counters (`stalls`, `force_resumes`, `disconnections`,
`compactions`, `turn_count`, `tool_calls`, `commands_executed`), rate-limit
payloads, output/event volume measurements, and output/events log paths. New
additive attempt counters are `attempts_total`, `attempts_succeeded`,
`attempts_failed`, `retry_count`, `throttle_429_count`, `disconnect_count`, and
`fallback_triggered`. Throughput values are populated only for a
sidecar-accepted outcome: `throughput_tokens_per_s` and
`throughput_successes_per_h`; `retry_tax_pct` is `0.0` when no retry occurred
and `null` until a retry source can measure attributable wasted tokens.

`cost_usd` is adapter/provider-reported approximate USD cost when the adapter
has a reliable structured source (for example Pi RPC `get_session_stats.cost`);
it remains `null` for adapters without reliable cost telemetry. Read `usage`
with it to distinguish an unavailable value from a genuine zero.

Examples for downstream analysis (never treat missing usage as zero):

```bash
# Accepted successes per hour, grouped by project/phase/effective model.
jq -s 'map(select(.outcome.status == "accepted" and .attribution.status == "complete"))
  | group_by([.attribution.project_id, .attribution.phase, .agent.model_effective])
  | map({group: .[0].attribution.project_id + "/" + .[0].attribution.phase + "/" + .[0].agent.model_effective,
         successes_per_hour: ((length * 3600) / (map(.actual.duration_s) | add))})' .harnex/dispatch.jsonl

# Retry and real-disconnect rates for completed rows.
jq -s 'map(select(.actual.attempts_total > 0))
  | {retry_rate: ((map(.actual.retry_count) | add) / (map(.actual.attempts_total) | add)),
     disconnect_rate: ((map(.actual.disconnect_count) | add) / (map(.actual.attempts_total) | add))}' .harnex/dispatch.jsonl
```

## Exit taxonomy

- `success`: wrapped process exited `0` and a session summary was parsed.
- `failure`: wrapped process exited non-zero.
- `timeout`: wrapped process exited with code `124`.
- `boot_failure`: JSON-RPC app-server exited within the startup window before a
  turn was observed.
- `disconnected`: wrapped process exited `0` but no session summary was parsed.

Summary file writes are best-effort. Write failures are printed as warnings and
do not change the wrapped process exit code.
