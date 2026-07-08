---
status: open
priority: P1
issue_kind: slice
created: 2026-07-08
updated: 2026-07-08
tags: telemetry,artifacts,validation,queue,koder,harnex
---

# Issue 52 — Typed artifact and validation sidecar reports

## Problem

Harnex is becoming the durable execution layer for `koder/` queue work. It now
has reliable work-level completion (`wait/watch --until done`), dispatch history,
queue-aware telemetry proposals (#47), and throughput telemetry proposals (#43).
But worker proof still usually comes back through one of three weak channels:

- prose in the final agent message;
- ad-hoc files named by the worker brief;
- pane/log inspection by the orchestrator.

That makes queue closeout and post-hoc analysis more brittle than necessary. A
worker may have run the right validation, found real risks, or emitted a useful
review verdict, but downstream tools cannot trustably read that proof without
scraping prose or re-opening transcripts.

The desired direction is not to import a heavyweight swarm/orchestrator model.
`koder/` plain-text artifacts should remain the canonical, evolving source of
truth beside the code. Harnex only needs a small machine-readable report contract
that links dispatch telemetry to those human-readable artifacts and validation
facts.

## Source / inspiration

Review of `professorpalmer/Puppetmaster` at `59b57ff` (2026-07-07) highlighted a
useful narrow idea: workers emit typed artifacts with evidence, confidence,
validation, and hashes, and the supervisor synthesizes from those structured
records rather than raw transcripts.

Adopt the small contract, not the whole product:

- keep `koder/` docs/issues/plans/queues as plain text and git-reviewed;
- do not add hidden canonical SQLite project memory;
- do not add global auto-invocation hooks;
- do not turn harnex into a provider/model framework;
- use sidecars as dispatch evidence and queue telemetry.

## Goal

Add a bounded JSON sidecar/report contract that a harnex worker can write and
that harnex ingests at dispatch finalization.

The contract should answer, without prose scraping:

1. What validation commands were run and did they pass?
2. What typed evidence did the worker produce: finding, decision, risk, review,
   patch summary, gate, or blocker?
3. Which plain-text `koder/` artifact or file path is the canonical human-readable
   source for the result?
4. What evidence/confidence/hash can downstream queue tooling record?

## Proposed v1 shape

Prefer one generic artifact report that can include validation. A narrower
`--validation-report` alias is acceptable if implementation is easier.

Example worker-produced JSON:

```json
{
  "schema": "harnex.artifact_report.v1",
  "status": "pass",
  "canonical_artifacts": [
    "koder/plans/52_typed_artifact_sidecars/INDEX.md",
    "koder/reviews/52_sidecar_contract/01_review.md"
  ],
  "validation": {
    "status": "pass",
    "commands": [
      {
        "cmd": "ruby -Ilib -Itest -e 'Dir[\"test/**/*_test.rb\"].each { |f| require_relative f }'",
        "exit_code": 0
      }
    ],
    "final_reported": true
  },
  "artifacts": [
    {
      "type": "finding",
      "summary": "Validation report ingestion must fail soft on malformed sidecars.",
      "evidence": ["lib/harnex/commands/run.rb:finalize"],
      "confidence": 0.86,
      "canonical_ref": "koder/issues/52_typed_artifact_validation_sidecars.md"
    },
    {
      "type": "gate",
      "summary": "Full suite passed.",
      "evidence": ["test output: 487 runs, 1672 assertions, 0 failures"],
      "confidence": 1.0
    }
  ]
}
```

Suggested launch surface:

```bash
harnex run pi --id pi-i-52 --tmux pi-i-52 \
  --artifact-report .harnex/reports/pi-i-52-artifacts.json \
  --context "Read koder/issues/52_typed_artifact_validation_sidecars.md. Write your report to $HARNEX_ARTIFACT_REPORT_PATH."
```

Implementation may choose to auto-create a default report path only when a flag
is present. The important part is that the worker sees an environment variable
such as `HARNEX_ARTIFACT_REPORT_PATH` and the finalizer knows where to read it.

## Dispatch summary integration

At finalize, harnex should:

- read the report if the path was configured;
- validate it as a bounded JSON object, with a strict size cap;
- fail soft on missing/malformed reports by recording a warning, not crashing the
  wrapped agent process;
- copy compact fields into the dispatch summary under additive top-level blocks,
  aligned with #47:
  - `validation` for command/status proof;
  - `artifacts` or `artifact_report` for typed summaries, canonical refs, report
    path, size, and sha256;
- avoid storing large raw transcripts or full private payloads in the dispatch
  row;
- keep old `meta`/`actual` fields compatible.

## Acceptance criteria

- [ ] `harnex run` accepts an artifact/validation report path, or equivalent
      metadata, and exposes the path to the worker as an environment variable.
- [ ] Dispatch finalization ingests a valid v1 report and records compact
      validation/artifact data in the summary JSONL row.
- [ ] Missing report, malformed JSON, unsupported schema, and oversized report
      are handled with explicit warning telemetry and no wrapped-process crash.
- [ ] Validation command results can be represented without scraping final prose.
- [ ] Typed artifacts include at least `type`, `summary`, `evidence`,
      `confidence`, and optional `canonical_ref`.
- [ ] The dispatch row records report path, byte size, and sha256 so queue
      closeout can link to the exact sidecar.
- [ ] Docs and `harnex agents-guide` show workers writing the sidecar while
      keeping canonical explanations in plain-text `koder/` artifacts.
- [ ] Tests cover valid report ingestion, missing/malformed/oversized reports,
      and backward compatibility when no report path is configured.

## Out of scope

- Replacing `koder/` plain-text artifacts as source of truth.
- A full Puppetmaster-style job/task SQLite store.
- Prose scraping from final agent messages.
- Automatic model routing or provider fallback.
- A dashboard UI; this contract should make a later dashboard easier but should
  not depend on one.
- Installing hooks, MCP rules, or any global auto-delegation layer.

## Relationship to existing issues

- Extends #47 by providing the explicit validation/report sidecar that issue
  already prefers over prose scraping.
- Supports #43 by making accepted work, retry waste, and validation outcomes more
  machine-readable.
- Complements #51 because `harnex watch --until done` can prove terminal work
  state, while this sidecar proves task acceptance criteria.

## Triage

- **Tier**: B
- **Plan count**: 1
- **Estimated sessions**: 1-2
- **Estimated wall-clock**: ~3-5h

## Notes

This should preserve the `koder-pattern` experience: humans and agents still
review and evolve durable docs beside code. Harnex gains a reliable evidence
index so queue runners do not need to read panes or trust prose summaries for
basic validation facts.
