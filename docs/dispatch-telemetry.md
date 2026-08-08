# Dispatch Telemetry

`harnex run` captures predicted-vs-actual dispatch telemetry for a wrapped
agent session. Raw measurements remain on the v1 per-session events stream.
Durable summaries use one canonical v2 dispatch stream: every run appends one
`dispatch_start` row at registration and one rich `dispatch_end` row at
teardown.

Inside a git repo the stream is `<git-root>/.harnex/dispatch.jsonl`; outside a
git repo it is `~/.local/state/harnex/dispatch.jsonl`. `harnex history`,
`status --id`, and `wait` consume the same rows. Legacy v1 thin rows and
pre-v2 envelope-less summaries may coexist and remain readable/skippable.

## Clean-Tree Checks And The Tracked Stream

Some repos deliberately track `.harnex/dispatch.jsonl` as project telemetry.
There the stream grows while sessions run, so worker briefs, completion
fences, and orchestration clean-tree checks must treat the path as
harness-owned: expected to be dirty mid-run, never foreign dirt to abort on,
and never a file a worker should revert or "clean up". Exclude it explicitly,
for example `git status --porcelain -- . ':!.harnex'`, and commit its growth
alongside the work it describes.

## CLI flags

```text
harnex run codex --meta '{"model":"gpt-5.3-codex","effort":"high","predicted":{"input_tokens":[200000,800000]}}'
harnex run pi --context 'Implement the task; Harnex writes the final receipt'
harnex run pi --artifact-report .harnex/receipts/pi-r-64.json --context 'Optionally write review claims to $HARNEX_ARTIFACT_CLAIMS_PATH'
harnex run pi --project-id harnex --queue-id queue-005 --entry-id SP-4 --phase implement --intent queue-work --require-attribution
harnex run pi --orchestration-run-id queue-005 --orchestration-generation-id gen-1 --orchestration-role worker
harnex orchestration report --dispatch .harnex/dispatch.jsonl --run-id queue-005 --json
```

- `--meta JSON` must be a JSON object. The parsed object is echoed verbatim on
  the `started.meta` event.
- Every run allocates a harness-owned `harnex.artifact_report.v1` receipt path.
  The default is a repo-keyed file under `~/.local/state/harnex/receipts/`; live status
  and the end row expose it as `artifact_report_path` / `artifact_report.path`.
- `--artifact-report PATH` overrides that output destination.
  `--validation-report PATH` remains a compatibility alias. The worker receives
  the final path as `HARNEX_ARTIFACT_REPORT_PATH` /
  `HARNEX_VALIDATION_REPORT_PATH`, but Harnex owns and overwrites that file.
- `HARNEX_ARTIFACT_CLAIMS_PATH` is a separate optional input for bounded
  `summary`, `verdict`, and `P1`/`P2`/`P3` counts. Claims are never acceptance
  evidence. Stale, malformed, or oversized claims are ignored.
- `--require-artifact-report` is retained for script compatibility and exports
  `HARNEX_ARTIFACT_REPORT_REQUIRED=1`, but it no longer needs an explicit path
  or model-authored report. Receipt write failure is fail-closed for every run.
- `harnex artifact-report validate PATH --final` validates the generated
  receipt without echoing its contents. `init` and the old final-validation
  contract remain available for legacy/manual v1 documents.
- `--project-id`, `--queue-id`, `--entry-id`, `--entry-title`, `--phase`,
  `--tier`, `--issue`, `--plan`, `--intent`, `--model`, `--effort`,
  `--parent-dispatch-id`, `--parent-attempt-id`, and `--attempt-kind` are
  first-class queue/agent telemetry flags. They are persisted as caller-provided
  strings and override same-named `--meta` values. `--attempt-kind` is one of
  `initial`, `retry`, `fix`, `review`, `fallback`, or `superseding`; linkage fields keep
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
- The canonical stream is the only destination a dispatch writes telemetry to.
  There is no second copy and no flag to request one; a flag asking for a
  mirror file is rejected as unknown. See CHANGELOG for the removal note.
- The v2 `dispatch_end` combines the history envelope (`schema_version`,
  `record_type`, id/status/timing fields) with all rich telemetry sections.
  A default dispatch therefore adds exactly two rows, not separate thin and
  rich end rows.

Use `harnex history --json | jq .` for pipelines over the repo-local log.

## Canonical assertion and reconciliation

`harnex telemetry assert-canonical` is the read-only drift gate for the
canonical dispatch stream. Without sources it performs structural validation;
with explicit `--source PATH` inputs it also reports missing or conflicting rich
end rows and exits non-zero until the canonical stream is clean.

`harnex telemetry reconcile` runs the same analysis. It is a dry-run by default;
only `--apply` appends missing rich end rows, and then only after the canonical
stream and all source candidates have been parsed and conflict-checked. Apply
uses one append lock, rechecks under that lock, and is idempotent.

```text
harnex telemetry assert-canonical [--canonical PATH | --global] [--source PATH ...] [--json]
harnex telemetry reconcile [--canonical PATH | --global] --source PATH [--source PATH ...] [--apply] [--json]
```

The default canonical path is the repo-local `.harnex/dispatch.jsonl`, or the
global dispatch stream outside a git repo. `--canonical` and `--global` are
mutually exclusive. Sources are never discovered automatically: each `--source`
must be a file or directory. Directory scans consider regular `.json` and
`.jsonl` files, skip `.git`, symlinks, and the resolved canonical path, and
ignore unrelated JSON that does not match a rich Harnex dispatch end shape.

Mixed-era history is valid input. Legacy v1 thin rows, pre-v2 envelope-less rich
summaries, and v2 start/end rows may coexist. Open v2 starts are tolerated
because a running or interrupted dispatch may not have an end row yet. Identity
checks normalize equivalent timestamp offsets, and conflicts fail closed rather
than choosing a winner.

Reports are bounded and redacted: they contain counts, statuses, identities, and
path:line diagnostics, not raw telemetry payloads, prompts, claims, command
text, or rich sections. The commands never rewrite, delete, sort, migrate,
clean source files, reintroduce mirrors, or perform source discovery on their
own.

## Metadata and prediction contract

The v2 `dispatch_end` always has `meta`, `predicted`, `actual`, `agent`,
`usage`, `context`, `attribution`, `outcome`, `attempt`, `reliability`,
`artifact_report`, `receipt`, `observed`, and `validation` blocks. When queue
attribution fields are provided, harnex also adds a top-level `queue` block.
When orchestration fields are provided, harnex adds a top-level
`orchestration` block. A sanitized `claims` block is additive only when the
worker supplied one.

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
top-level keys are kept on `started.meta` but are not copied into the v2 end
row.

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
    "cost_source": "price_table",
    "cost_price_as_of": "2026-08-03",
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
provided no observation. `cost_source` is `provider_reported` for a reliable
adapter value, `price_table` when Harnex computes exact maintained
provider/model/service-tier/context-band list pricing, and `caller_estimate` for
a declared estimate. Price-table rows carry `cost_price_as_of`; unknown models,
service/context tiers, missing context evidence, or required token components
remain null. Provider-reported values are never
overwritten, and all cost telemetry is operational estimation rather than a
billing invoice.

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
is incomplete; otherwise `missing`. `outcome.status` is derived from the
harness receipt: `accepted`, `rejected`, `no_change`, or `unknown`. Optional
worker claims cannot set it. Its additive `class` records the work verdict
(`completed_with_proof`, `completed_no_activity`, `report_invalid`,
`task_failed`, plus legacy classes retained in old rows), and `report_status`
is normally `accepted` or `rejected`. `source=harnex_observed_state` identifies
new receipts. The block also contains final commit/path/LOC observations; those
facts prove the delta, not semantic quality or human authorship.

Every end row has one Harnex-session `attempt`. Its random `id` is distinct
from operator-visible `run_id`; `parent_attempt_id` and `parent_dispatch_id`
link retries/fixes/reviews/fallbacks while each row keeps separate raw usage.
At finalization Harnex walks the canonical stream's parent chain once to derive
`actual.attempts_total`, succeeded/failed counts, `fallback_triggered`, and
`reliability.recovered`; missing parents and malformed/cyclic history degrade
safely to the resolvable chain. `retry_count` remains the separate in-run event
counter. The events JSONL also carries `attempt_started`, `attempt_finished`,
and adapter-reported retry/fallback events.

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

## Observed-state receipts and optional claims

Every dispatch receives a bounded receipt authored by Harnex, not by the
worker. The schema identifier remains `harnex.artifact_report.v1` so existing
`artifact-report validate --final` consumers keep one command and one result
contract. The additive `receipt.author=harnex` marker selects the observed-state
final contract.

A generated receipt contains:

```json
{
  "schema": "harnex.artifact_report.v1",
  "status": "pass",
  "receipt": {
    "version": 1,
    "author": "harnex",
    "generated_at": "2026-08-03T05:00:00Z",
    "id": "cx-r-64",
    "session_id": "8d8f3f07c8fc343d"
  },
  "outcome": {
    "status": "no_change",
    "summary": "Harnex observed successful completion with no Git delta."
  },
  "validation": {
    "status": "pass",
    "final_reported": true,
    "commands": [
      { "cmd": "git diff --check", "exit_code": 0, "status": "completed" }
    ]
  },
  "observed": {
    "git": {
      "status": "observed",
      "start_sha": "0123456789abcdef0123456789abcdef01234567",
      "end_sha": "0123456789abcdef0123456789abcdef01234567",
      "branch": "main",
      "changed_paths": [],
      "loc_added": 0,
      "loc_removed": 0,
      "files_changed": 0,
      "commits": 0
    },
    "commands": [
      { "cmd": "git diff --check", "exit_code": 0, "status": "completed" }
    ],
    "command_observation": "observed",
    "turn": {
      "status": "completed",
      "outcome_class": "completed_with_proof",
      "task_complete": true,
      "task_failed": false,
      "accepted": true,
      "exit_code": 0
    },
    "usage": { "status": "observed", "input_tokens": 100, "output_tokens": 20, "total_tokens": 120 }
  }
}
```

`observed.git` is sufficient for a queue to distinguish commit proof
(`start_sha != end_sha`, commit count/path/LOC evidence) from an observed
`no_change` result. `start_dirty`, `end_dirty`, and `worktree_changed` expose
worktree caveats while unchanged pre-session dirt is excluded from the delta.
Codex app-server `commandExecution` items contribute
bounded command text, integer exit code, status, and optional duration. Other
transports currently report `command_observation: "unsupported"` rather than
guessing from prose or generic tool events. If the 256-KiB receipt cap requires
trimming, `commands_truncated` / `changed_paths_truncated` make that explicit;
full aggregate counts remain in the dispatch row. Usage carries the same
measured/missing/unsupported semantics as the dispatch
row and is refreshed at teardown when final adapter usage becomes available.

`validation.commands` mirrors all bounded observed command exits for legacy
readers. Its aggregate status is `not_run`, `pass`, or `fail`; a failed
exploratory command may precede a successful turn. For harness receipts,
`validate --final` therefore validates receipt authorship/shape, accepted turn,
and accepted/no-change outcome instead of letting an intermediate command exit
rewrite the harness verdict. Queue policy may impose a stricter command gate by
inspecting `observed.commands`.

Reviewers can write one optional input file at
`HARNEX_ARTIFACT_CLAIMS_PATH`:

```json
{
  "claims": {
    "summary": "Review complete; one P2 remains.",
    "verdict": "changes_requested",
    "findings": { "P1": 0, "P2": 1, "P3": 0 }
  }
}
```

Only those bounded fields are copied. Claims are informational and never affect
receipt validity, `outcome.status`, or the completion gate. The fingerprint of
a configured pre-existing file is used only to avoid ingesting stale claims;
Harnex always atomically replaces the final receipt, eliminating the old
missing/stale-proof acceptance race. Legacy workers that still write a full v1
file may contribute its outcome summary/status as advisory claims, but Harnex
replaces the document and ignores it for acceptance.

`artifact_report` in the dispatch row records final path, bytes, SHA-256,
schema, ingest status, report status, and author. `receipt`, `observed`, and
`validation` are compact top-level copies; `claims` appears only when present.
The default receipt path is outside the checkout so proof generation cannot
pollute the Git delta. An explicit path is supported when a queue requires one.
Receipt write/validation failure is typed `report_invalid` and fails closed.
Harnex never scrapes report-shaped final prose or copies full transcripts.

`harnex artifact-report init` still creates the older manual skeleton, and the
validator still accepts that legacy final contract. It is compatibility tooling,
not a required worker step for new dispatches.

## Autonomous completion gate

For Codex app-server runs launched with `--context`, provider turn completion
is not by itself accepted work completion. Harnex emits `task_complete` only
when it has at least one structured command/tool/file-change item or a Git
delta. If both are absent, it emits `task_failed` with
`outcome_class=completed_no_activity`, writes a rejected observed receipt, and
normalizes auto-stop to non-zero. This applies equally to
`service_tier=flex` and `service_tier=fast` and deliberately ignores final
answer text and claims. Intentional no-op work must still perform observable
inspection/validation; a model assertion of `no_change` cannot self-approve.

PTY transports do not expose equivalent completion-item metadata, so their
existing prompt-return auto-stop behavior remains. Non-Codex transports label
command observation `unsupported`; Git and terminal state are still recorded
without guessing.

## Actuals

At process exit, harnex collects usage through the active adapter. JSON-RPC
Codex sessions read cumulative `thread/tokenUsage/updated` data, Pi RPC sessions
read `get_session_stats`, and PTY adapters parse the last 16 KB of transcript
when they support a parser. Adapters without a parser emit nullable usage
fields. Separately, Pi aggregates bounded `contextUsage` samples and Codex
aggregates `tokenUsage.last` plus `modelContextWindow`; neither source is
substituted with cumulative usage when active occupancy is unavailable.

Git actuals capture the start/end SHA plus committed, staged, unstaged, and
untracked changes relative to the worktree state observed at session start.
Unchanged pre-existing dirt is not credited to the worker, and harness-owned
dispatch/receipt paths are excluded. Git failures leave the corresponding
consolidated fields `null` and omit `git` events.

The `actual` block includes model/effort hints from `--meta`, duration, token
counts, `agent_session_id`, compatibility `cost_usd`, adapter transport, git
deltas, exit reason, task completion state, signal/exit code, last error,
operational counters (`stalls`, `force_resumes`, `disconnections`,
`compactions`, `turn_count`, `tool_calls`, `commands_executed`), rate-limit
payloads, output/event volume measurements, and output/events log paths. New
additive attempt counters are `attempts_total`, `attempts_succeeded`,
`attempts_failed`, `retry_count`, `throttle_429_count`, `disconnect_count`, and
`fallback_triggered`. Throughput values are populated only for a
harness-accepted outcome: `throughput_tokens_per_s` and
`throughput_successes_per_h`; `retry_tax_pct` is `0.0` when no retry occurred
and `null` until a retry source can measure attributable wasted tokens.

Legacy `actual.cost_usd` reflects adapter/provider-reported cost only. Prefer
the top-level `usage` block: it also carries price-table-derived cost and its
`cost_source` / `cost_price_as_of` provenance. Claude PTY currently has no
bounded usage producer and reports `unsupported`; it is not silently priced.

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

- `success`: wrapped process exited `0` with task completion, accepted observed
  receipt proof, or an adapter session summary.
- `failure`: wrapped process exited non-zero, the observed-activity gate emitted
  `task_failed`, or Harnex could not write/validate the receipt.
- `timeout`: wrapped process exited with code `124`.
- `boot_failure`: JSON-RPC app-server exited within the startup window before a
  turn was observed.
- `disconnected`: wrapped process exited `0` but no session summary was parsed.

Canonical dispatch-stream writes remain best-effort. Receipt
writes are different: proof-generation failure is fail-closed and changes the
work verdict. Repo phase allowlists and runtime-log retention are documented in
[configuration.md](configuration.md).
