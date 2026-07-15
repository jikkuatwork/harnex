---
status: open
priority: P1
issue_kind: slice
created: 2026-07-15
updated: 2026-07-15
tags: artifact-report,validation,completion,queue,strict-mode,reliability
---

# Issue 61 — Strict artifact-report acceptance and schema tooling

## Problem

Issue #52 intentionally made missing and malformed artifact reports fail soft.
That is appropriate for optional telemetry, but unsafe when a blind queue names
the report as required completion proof.

Holm Queue `086` exposed both failure shapes on 2026-07-15:

- `cx-r-655tq86` and `cx-r2-655tq86` completed and committed valid review
  artifacts, then printed report-shaped JSON in their final answers instead of
  writing `$HARNEX_ARTIFACT_REPORT_PATH`. Harnex still reported success.
- `cx-i-655q86` produced green implementation WIP and wrote a JSON file, but it
  omitted `schema`, used a string `outcome`, and omitted command exit codes.
  The worker's `jq -e` check proved JSON syntax only, not
  `harnex.artifact_report.v1` conformance.

This forced the coordinator to reconstruct proof manually and eventually stop
a green entry on reporting defects rather than product failure.

## Goal

Provide an opt-in strict proof contract plus deterministic worker tooling:

1. `--require-artifact-report` (or equivalent) makes a configured report part
   of work acceptance, not advisory telemetry.
2. Missing, malformed, unsupported, oversized, or contract-incomplete reports
   produce a typed non-success outcome and nonzero watch/run verdict.
3. Add a CLI/library validator for the real schema, for example
   `harnex artifact-report validate PATH`, with machine-readable diagnostics.
4. Add a bounded initializer/template helper so workers do not handcraft JSON,
   for example `harnex artifact-report init PATH` using the current schema.
5. In strict mode, `--auto-stop` reports success only after the report is
   ingested and accepted.

## Acceptance Criteria

- [ ] Strict mode fails closed when the sidecar file is absent even if the agent
      returned a normal final answer.
- [ ] Strict mode rejects syntactically valid but schema-invalid JSON, including
      a missing schema and string-valued `outcome`.
- [ ] Validator diagnostics name the failing field/shape without exposing
      report payloads or transcripts.
- [ ] A helper emits a valid minimal `harnex.artifact_report.v1` skeleton and
      supports final validation without models reproducing schema prose.
- [ ] Final dispatch telemetry distinguishes `report_missing`,
      `report_invalid`, and accepted proof using #57's outcome vocabulary.
- [ ] Existing fail-soft behavior remains available when strict mode is not
      requested.
- [ ] Tests cover JSON printed only in final prose: it must not satisfy the
      required sidecar contract, and Harnex must not scrape it.
- [ ] Agent guides show strict mode for blind/unattended queue work.

## Related

- #52 — fail-soft typed sidecar ingestion (implemented in 0.7.10).
- #56 — adapter preflight should exercise strict report acceptance.
- #57 — outcome classes and failure-budget accounting.
- #59 — conveyor runner should request strict proof.

## Non-Goals

- Replacing canonical Markdown artifacts.
- Scraping final agent prose for JSON.
- Semantic review of the worker's code or findings.
