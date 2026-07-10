---
status: closed
priority: P1
---

# Issue 47 — Queue-aware dispatch telemetry contract

**Status**: closed
**Priority**: P1
**Filed**: 2026-05-24
**Tier**: B (plan -> impl -> verification)
**Sister**: extends #43 (throughput-first telemetry v2), #46 (cost telemetry), and #44 (Pi RPC adapter).

## Problem

Harnex dispatch rows are now used as production build telemetry for queue-driven
agent workflows, but the current schema still loses important queue attribution
and reliability semantics.

Recent queue runs showed successful dispatches with useful token/LOC/commit
summaries, but several fields remained missing or ambiguous:

- queue identity and queue entry identity are not first-class
- `phase`, `tier`, `issue`, `plan`, `model`, and `effort` can be null even when
  the caller knew them before dispatch
- validation outcomes are only recoverable from free-form final messages or logs
- successful structured-adapter sessions can still report a generic
  `disconnections` count, making normal adapter close look like reliability tax
- downstream tools must infer project/queue economics from paths, ids, and
  heuristics instead of reading a stable contract

This limits throughput, routing, and cost analysis precisely when Harnex is
becoming the durable execution layer for queued work.

## Goal

Make queue-aware dispatch telemetry a stable additive contract so external
orchestrators can pass work metadata into Harnex and downstream tools can answer:

1. Which queue entry produced this commit?
2. Which issue/plan/phase/tier/model/effort was used?
3. Which validation commands passed or failed?
4. How much work, token volume, cost, and wall time did the entry consume?
5. Did the run have a real reliability event, or only a normal adapter shutdown?

## Proposed telemetry additions

### 1) Queue attribution block

Add an optional top-level `queue` block to dispatch summaries. Do not nest the
new queue contract under `meta`; keep existing `meta.*` fields for compatibility
only.

```json
{
  "queue": {
    "project_id": "harnex",
    "queue_id": "005_policy_backup_operator_foundation",
    "entry_id": "SP-4",
    "entry_title": "Implement system policy SDK docs SP-4",
    "issue": "451",
    "plan": "451",
    "phase": "implement",
    "tier": "B",
    "intent": "sdk-docs-cutover"
  }
}
```

Use `null` only when genuinely unknown. If the caller provides these values,
Harnex should persist them unchanged. Treat ids as pass-through strings, not
integers, because queue ids, entries, issue labels, and external plan ids can be
non-numeric.

### 2) Effective agent/model block

Persist requested and effective routing details:

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

Keep existing `meta.agent*` / `actual.model` fields for compatibility, but give
new consumers a stable nested home.

### 3) Validation summary

Capture machine-readable validation results when the worker reports them or when
Harnex can classify executed commands:

```json
{
  "validation": {
    "status": "pass",
    "commands": [
      { "cmd": "go test ./cmd/server -count=1", "exit_code": 0 }
    ],
    "final_reported": true
  }
}
```

Validation v1 should not scrape prose final answers. Prefer an explicit JSON
sidecar/report contract, e.g. `--validation-report PATH` or
`HARNEX_VALIDATION_REPORT_PATH`, that workers can write and Harnex reads at
finalize. Command intent inference can remain out of scope for v1.

### 4) Reliability semantics split

Replace or supplement the ambiguous `actual.disconnections` counter with fields
that distinguish normal adapter lifecycle from real failures:

- `reliability.adapter_close`: `normal | interrupted | lost | unknown`
- `reliability.real_disconnections`
- `reliability.stream_interruptions`
- `reliability.stalls`
- `reliability.force_resumes`
- `reliability.compactions`
- `reliability.recovered`

Successful one-turn structured runs should not look degraded just because the
adapter/socket closed normally after task completion.

### 5) Strict attribution option

Add a flag/config mode for orchestrators that want fail-fast metadata hygiene:

```bash
harnex run codex --require-attribution --queue-id ... --entry-id ... --phase ...
```

Default mode remains permissive and emits warnings instead of failing.

## Contract decisions

- Canonical new homes are top-level additive blocks: `queue`, `agent`,
  `validation`, and `reliability`.
- Existing `--meta` remains supported. First-class flags, when present, override
  same-named `--meta` values; tmux re-exec must forward both forms correctly.
- Existing `meta.*` and `actual.*` fields remain for compatibility, but new
  consumers should prefer the top-level blocks.
- Existing `actual.disconnections` is legacy/ambiguous unless/until separately
  migrated; v2 consumers should use `reliability.real_disconnections`.
- Strict attribution requires `project_id`, `phase`, and `intent` plus at least
  one of `queue_id`/`entry_id`/`issue`/`plan`.

## Acceptance Criteria

- [x] Harnex supports passing project/queue/entry/phase/tier/issue/plan/model/effort metadata at run start.
- [x] Dispatch summaries persist that metadata in a documented additive schema.
- [x] Structured adapters distinguish normal adapter close from real disconnection/recovery events.
- [x] A validation summary can be emitted from an explicit JSON sidecar/report without scraping prose final answers.
- [x] Schema tests cover queue attribution, effective model fields, validation summary, and reliability split.
- [x] `docs/dispatch-telemetry.md` documents the new fields and migration guidance from old fields.
- [x] Existing telemetry consumers remain compatible with current flat fields.
- [x] A sample analysis snippet can group dispatches by `project_id + queue_id + entry_id + phase + model_effective`.

## Out of scope

- Rewriting historical dispatch rows.
- Perfect cross-provider billing reconciliation.
- A full queue runner inside Harnex; this issue is the telemetry contract needed
  by external queue runners.

## Review turn — 2026-05-24

This issue looks worth keeping as a narrower queue-contract slice on top of #43,
but the implementation should make a few contract decisions before code lands:

1. **Choose one canonical schema location.** The issue currently says top-level
   or `meta.queue`. Prefer top-level additive blocks — `queue`, `agent`,
   `validation`, and `reliability` — while preserving existing `meta.*` and
   `actual.*` fields for compatibility.
2. **Clarify the gap from existing `--meta`.** Harnex already persists
   `tier`, `phase`, `issue`, `plan`, and `task_brief` when supplied through
   `--meta`. The real gap is that queue identity is not first-class, unknown
   metadata does not enter the consolidated row, and attribution is not
   validateable/strict.
3. **Define precedence.** If first-class flags are added (`--queue-id`,
   `--entry-id`, `--phase`, `--tier`, `--issue`, `--plan`, `--intent`, etc.),
   document whether explicit flags override `--meta` and ensure tmux re-exec
   forwards them.
4. **Add project attribution.** #43 asks for `project + phase + intent`; this
   issue currently has queue/entry attribution but no explicit project key.
   Add `project` or `project_id` so consumers do not infer project economics
   from paths.
5. **Treat IDs as pass-through strings.** Queue entries, issues, plans, and
   external IDs are often not integers (`SP-4`, `451A`, etc.). Document that
   Harnex persists caller-provided values unchanged; strings are safest.
6. **Make validation v1 explicit.** Avoid prose scraping. Prefer a small JSON
   sidecar/report contract such as `--validation-report PATH` or a
   `HARNEX_VALIDATION_REPORT_PATH` environment variable that workers can write
   and Harnex reads at finalize.
7. **Split reliability semantics from legacy counters.** Current structured
   adapter EOF/close can be counted as `actual.disconnections`, which makes a
   normal task-complete shutdown look degraded. For v1, add
   `reliability.adapter_close` and `reliability.real_disconnections`; either
   make legacy `actual.disconnections` mirror real disconnections going forward
   or explicitly document it as legacy/ambiguous.
8. **Normalize service tier carefully.** Codex currently defaults to `flex`
   unless `--fast` requests `fast`, so avoid a sample value like `default`
   unless it is a deliberate normalized enum.

Suggested v1 shape:

```json
{
  "queue": {
    "project_id": "harnex",
    "queue_id": "005_policy_backup_operator_foundation",
    "entry_id": "SP-4",
    "entry_title": "Implement system policy SDK docs SP-4",
    "issue": "451",
    "plan": "451",
    "phase": "implement",
    "tier": "B",
    "intent": "sdk-docs-cutover"
  },
  "agent": {
    "cli": "codex",
    "provider": "openai",
    "model_requested": "gpt-5.3-codex",
    "model_effective": "gpt-5.3-codex",
    "reasoning_effort": "high",
    "service_tier": "flex",
    "adapter_transport": "stdio_jsonrpc"
  },
  "validation": {
    "status": "pass",
    "commands": [
      { "cmd": "ruby -Ilib -Itest -e 'Dir[\"test/**/*_test.rb\"].each { |f| require_relative f }'", "exit_code": 0 }
    ],
    "final_reported": true
  },
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

Implementation may be easier as two slices: first attribution/agent/reliability
schema + docs/tests, then validation report ingestion.

## Response turn — 2026-05-24

Agreed with the review. The main issue body is updated to converge on these
points:

- top-level additive blocks are canonical (`queue`, `agent`, `validation`,
  `reliability`), not `meta.queue`
- `project_id` is required for strict attribution so consumers do not infer
  project economics from paths
- ids are caller-provided strings and must be persisted unchanged
- explicit first-class flags override same-named `--meta` values, and tmux
  re-exec must forward both paths
- validation v1 should use an explicit sidecar/report file, not prose scraping
- `actual.disconnections` remains legacy/ambiguous for compatibility; new
  consumers use `reliability.real_disconnections`
- Codex examples use `service_tier: "flex"`, matching current default behavior

Preferred implementation split remains: (1) attribution/agent/reliability schema
+ docs/tests; (2) validation report ingestion.

## Resolution

Implemented across `harnex 0.7.10` and `harnex 0.7.11`: #52 / 0.7.10 shipped
explicit artifact/validation sidecar ingestion; 0.7.11 shipped first-class queue
attribution flags, `--require-attribution`, and top-level `queue`, `agent`, and
`reliability` dispatch summary blocks. Legacy `meta` / `actual` fields remain
compatible; new consumers should prefer the top-level additive blocks.

## Triage

- **Tier**: B
- **Plan count**: 1
- **Estimated sessions**: 1-2
- **Estimated wall-clock**: ~3-5h

## Notes

#43 covers broader throughput-first telemetry. This issue is narrower: make
queue-driven work first-class enough that Harnex rows can be trusted as the
source of truth for queued build economics and reliability.
