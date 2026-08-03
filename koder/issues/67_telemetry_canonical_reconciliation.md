---
status: open
priority: P2
issue_kind: slice
created: 2026-08-03
updated: 2026-08-03
plan: 34
tags: telemetry, recovery, invariant, jsonl, cli
---

# Issue 67 — Canonical telemetry reconciliation and assertion

## Problem

Harnex `0.9.0` made `.harnex/dispatch.jsonl` the canonical rich telemetry
stream, and `0.10.0` removed the `--summary-out` mirror that repeatedly
stranded duplicate end rows in ignored scratch files. The writer defect is
closed, but recovery and regression checking remain manual.

Holm has now performed this forensics three times. Its latest pass had to:

1. discover rich rows in old scratch files;
2. identify a dispatch by `(id, started_at instant)` because ids are reused and
   timestamps can use different offsets;
3. distinguish byte/semantic duplicates from payload conflicts;
4. append only genuinely missing rows to the canonical stream; and
5. re-audit the result before deleting redundant mirrors.

That procedure belongs in harnex. A close/CI gate also needs a read-only way to
prove the canonical stream is structurally sound and that declared recovery
sources contain no missing or conflicting rich rows.

Source evidence: Holm Analysis `719` recovered 213 rows from 212 ignored files;
Analysis `720` classified this command pair as the remaining P2 machinery gap.

## Goal

Add one bounded command namespace:

```text
harnex telemetry assert-canonical [options]
harnex telemetry reconcile [options]
```

- `assert-canonical` is read-only and fail-closed for canonical corruption,
  modern-v2 pairing/uniqueness violations, and missing/conflicting rich records
  found in explicitly declared source paths.
- `reconcile` uses the same analysis, defaults to dry-run, and with `--apply`
  appends only missing rich end records under one lock. It never rewrites or
  deletes history.
- Both emit bounded reports containing identities/counts/path+line evidence,
  never raw telemetry payloads.
- Mixed historical streams remain valid: legacy thin v1 and envelope-less rich
  rows are tolerated rather than migrated.

## Non-goals

- Reintroducing any telemetry mirror or second writer.
- Rewriting, sorting, normalizing, deleting, or compacting canonical history.
- Automatically deleting source files after reconciliation.
- Treating an unpaired v2 start as corruption; interrupted/running dispatches
  legitimately have no end row.
- Migrating historical schemas to v2.
- Searching the whole filesystem or guessing consumer-specific scratch paths.
  Sources are explicit `--source` paths.
- Repairing semantic content inside an existing row.

## Safety contract

1. Canonical validation completes before mutation.
2. All source candidates are collected and conflict-checked before mutation.
3. Any malformed canonical line, invalid modern-v2 row, or identity conflict
   blocks the whole apply with zero appended rows.
4. Apply is append-only and idempotent. A crash after a partial OS write is
   surfaced as malformed canonical JSON on the next run; a completed partial
   candidate set is safe to rerun because existing rows are deduplicated.
5. Source directories skip symlinks and `.git`; unrelated valid JSON is ignored.
   Explicit malformed source files fail, while unrelated non-telemetry files
   encountered during directory discovery do not poison the scan.
6. Reports do not echo `meta`, prompts, claims, command text, or raw rows.

## Triage

- **Tier:** A.
- **Reasoning:** 2/4 yes. This introduces a new public CLI namespace and writes
  an append-only data-integrity surface. A wrong identity/conflict rule could
  silently duplicate or lose telemetry. It is not security-sensitive and does
  not span more than three runtime subsystems.
- **Phases:** plan review → RED test suite → RED review → implementation → code
  review → release gate. One plan only; no per-file decomposition.
- **TDD:** strict red → green. Tests must prove the mutation path is blocked on
  every conflict/corruption condition before implementation begins.
- **Release:** patch release `0.10.1` after independent code review and explicit
  owner confirmation at the publish gate.

## Acceptance criteria

- A clean mixed-era canonical stream passes `assert-canonical`.
- Malformed canonical JSON, duplicate v2 start/end identity, or a v2 end that
  does not match its start fails without mutation.
- Unpaired v2 starts are reported but pass.
- `--source` accepts a file or recursively scans a directory for `.json` and
  `.jsonl` candidates while excluding canonical, symlinks, and `.git`; directory
  sources ignore generic summaries unless they match the rich dispatch end
  shape.
- A source rich row absent from canonical makes `assert-canonical` and dry-run
  `reconcile` report drift and exit non-zero.
- `reconcile --apply` appends that row exactly once; a second apply is a no-op.
- v2 identity is `(session_id, id, normalized started_at UTC instant)`; same
  identity + different payload is a conflict and appends nothing.
- Legacy identities normalize equivalent ISO-8601 offsets before comparison.
- Default output is human-readable; `--json` emits one bounded JSON object.
- Full harnex suite passes, CLI help/docs describe the safety contract, and an
  installed-binary smoke proves dry-run → apply → clean/idempotent.

## Resolution

Open. Execute Plan 34.
