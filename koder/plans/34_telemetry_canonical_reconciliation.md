---
status: completed
issue: 67
plan: 34
tier: A
layer: canonical-telemetry-recovery
created: 2026-08-03
phases: 6
---

# Plan 34 — Canonical telemetry reconciliation and assertion (#67)

## Capability statement

Harnex gains a safe, bounded operator primitive for the last manual telemetry
forensics class: inspect a mixed-era canonical dispatch stream, compare it with
explicit legacy/mirror sources, append only provably missing rich end rows, and
assert the result at CI/close time without rewriting history.

This plan is deliberately one slice. Splitting scanner, command, and append
logic into separate plans would create tightly coupled glue phases over the
same files and repeat the machinery overhead this feature is intended to end.

## Current state and evidence

- `0.10.0` writes only `<git-root>/.harnex/dispatch.jsonl`; `--summary-out` is
  gone and hard-errors.
- `DispatchHistory` already owns canonical path resolution, start/end shape
  predicates, ISO timestamps, and locked append.
- `harnex history` deliberately accepts v1 thin rows and v2 rows while skipping
  older envelope-less rich rows.
- Holm's tracked stream currently mixes v1 thin, envelope-less rich, and v2
  start/end rows. Historical coexistence is a supported input, not drift.
- Holm Analysis `719` recovered 213 rich rows using `(id, started_at instant)`;
  Analysis `720` asks for this command pair and a close-time assertion.
- Upstream mirror recurrence is already prevented by #65. This plan adds
  recovery and verification; it must not recreate a second writer.

## Locked public CLI

```text
harnex telemetry assert-canonical \
  [--canonical PATH | --global] [--source PATH ...] [--json]

harnex telemetry reconcile \
  [--canonical PATH | --global] --source PATH [--source PATH ...] \
  [--apply] [--json]
```

Rules:

1. Default canonical path is `DispatchHistory.path_for(Dir.pwd)`.
2. `--canonical` and `--global` are mutually exclusive.
3. `--source` is repeatable and accepts a regular file or directory.
4. `reconcile` requires at least one source. Without `--apply` it is a dry-run.
5. `assert-canonical` without sources performs structural validation only.
6. Exit `0` means clean (or apply completed and post-check is clean); exit `1`
   means drift/corruption/conflict; option errors use the existing CLI parse
   contract.
7. Human output is default. `--json` prints one report object and no prose to
   stdout.

Do not add aliases, config, env knobs, automatic source discovery, or a generic
JSON repair framework.

## Record and identity contract

### Canonical rows

Every nonblank canonical line must parse as a JSON object. Three historical
families are accepted:

- v2 `dispatch_start`;
- v2 `dispatch_end` (rich);
- legacy end rows accepted by canonical validation: thin v1 and envelope-less
  rich (`meta` hash + `actual` hash). Envelope-less rich recovery is new
  reconciler behavior; current `harnex history` readers skip those rows.

Well-formed unknown historical objects are counted as `legacy_unknown` and
warned, not failed; readers already skip them. Malformed JSON is always fatal.

Modern v2 checks are strict:

- `schema_version == 2`;
- nonempty `id`, `session_id`, and parseable `started_at`;
- one start row and one end row per `(session_id, id, normalized started_at UTC
  instant)`;
- a v2 end must have exactly one start with matching `session_id`, `id`, and
  normalized `started_at` instant;
- a second v2 row with the same identity and record type is a duplicate if its
  parsed payload is equal, otherwise an identity conflict;
- an unpaired start is allowed and counted as `open_starts`.

### Recoverable source candidates

Only rich dispatch end records are recoverable:

- v2 `schema_version == 2` and `record_type == "dispatch_end"`, with nonempty
  `session_id`, nonempty `id`, parseable `started_at`, and an `actual` hash; or
- envelope-less legacy rich dispatch summaries with `meta` hash, nonempty
  `meta.id`, parseable `meta.started_at`, an `actual` hash, and at least two
  additional known harnex rich-summary section keys from this set: `predicted`,
  `agent`, `usage`, `context`, `attribution`, `outcome`, `attempt`,
  `reliability`.

Thin v1 rows, start rows, generic JSON, queue summaries, receipts, and claims
are ignored as recovery candidates. A directory-discovered file whose only
would-be candidates fail the rich-dispatch shape is ignored, not treated as
malformed telemetry.

Identity:

- v2 rich end rows require nonempty `session_id`, nonempty `id`, and parseable
  `started_at`. Their identity is `(session_id, id, normalized started_at UTC
  instant)`. `session_id` is an additional discriminator, not a substitute for
  dispatch ID and start instant.
- envelope-less legacy rich rows have no trusted session ID. Their identity is
  `(id, normalized started_at UTC instant)` where both fields come from `meta`.
- Canonical duplicate/conflict checks compare identities inside the same
  family. A v2 row and a legacy rich row may be considered the same recovered
  dispatch only when `id` and normalized `started_at` match and their
  recoverable payload is semantically equal; otherwise report a conflict with
  both path:line locations.

Comparison uses parsed JSON object equality for payloads, not byte order.
Equivalent timezone offsets normalize for identity only; payload text is not
rewritten.

## Source discovery contract

- Explicit file: parse as one JSON document when possible, otherwise JSONL.
  Malformed explicit input is fatal.
- Directory: recursively inspect regular `.json`/`.jsonl` files; do not follow
  symlinks; prune `.git`; exclude the resolved canonical path.
- During directory discovery, unrelated JSON and files with no recoverable rich
  records are ignored. A file containing at least one recoverable record must
  be internally parseable; malformed sibling lines make that source fatal.
- Deduplicate repeated/same-resolved source paths before scanning.
- Keep reports bounded: counts plus at most 50 path:line/identity diagnostics,
  with a truncated count. Never include raw row values or rich sections.

If implementing the explicit-file-vs-directory parse distinction requires a
large generic parser, stop and use a narrower documented JSONL-only source
contract rather than expanding scope.

## Mutation contract

`reconcile --apply`:

1. Parse and validate the complete canonical stream.
2. Discover and parse all source candidates.
3. Build the full missing/present/conflict result in memory.
4. If any fatal or conflict exists, return `1` with zero writes.
5. Sort missing rows by normalized start instant, source path, and source line.
6. Acquire one exclusive lock on canonical, re-read/revalidate identities under
   the lock to close the analysis/write race, then append only still-missing
   rows in one buffered write.
7. Flush, release, and run the same assertion again; success requires clean.

No temp-file replacement, rewrite, deletion, migration, source cleanup, or
canonical sorting. Existing `DispatchHistory.append` may be extracted/reused,
but one lock for the whole batch is required; do not take one lock per row.

## Report contract

Use one stable report shape for both subcommands, for example:

```json
{
  "schema": "harnex.telemetry_reconcile.v1",
  "command": "assert-canonical",
  "status": "clean",
  "canonical": ".harnex/dispatch.jsonl",
  "canonical_rows": 3563,
  "families": {"v2_start": 49, "v2_end": 49, "v1_end": 2043, "legacy_rich": 1422, "legacy_unknown": 0},
  "sources": {"paths": 1, "files_scanned": 10, "candidates": 0},
  "present": 0,
  "missing": 0,
  "conflicts": 0,
  "open_starts": 0,
  "appended": 0,
  "diagnostics": [],
  "diagnostics_truncated": 0
}
```

Exact key naming may change in plan review, but tests must pin one versioned,
bounded, payload-free contract. Human output derives from this report.

## Phase 1 — Independent plan review

A fresh reviewer checks:

- the identity rule against mixed v1/rich/v2 history and id reuse;
- no path causes rewrite/deletion or partial writes after a known conflict;
- source discovery cannot mistake queue/session summaries for rich dispatches;
- modern-v2 checks tolerate valid unpaired starts;
- the CLI is small enough for one plan.

Review only; no source edits or test execution. Amend this plan only for P1/P2
findings before RED tests.

## Phase 2 — RED tests first

Add focused tests before production code, but stage the executable contract so
the first RED proves only the missing command seam instead of masking every
behavior behind one unknown top-level command.

### RED-0 — command route/help absence

Existing evidence is sufficient: commit `b38a143` runs the new file with
`11 runs, 29 assertions, 11 failures, 0 errors`, and RED review `8931731`
rejected it because each contract is hidden behind the same absent
`telemetry` route in `lib/harnex/cli.rb`.

### GREEN-0 — minimal skeleton only

The first production commit is limited to:

- require and route `harnex telemetry` plus `harnex help telemetry`;
- parse only the approved `assert-canonical` / `reconcile` subcommands and
  options, including `--canonical`/`--global`, repeatable `--source`, `--apply`,
  and `--json`;
- emit one bounded `harnex.telemetry_reconcile.v1` report shell with
  `status: not_implemented` for executable subcommands and exit nonzero;
- perform path/option resolution only. No canonical/source file reads, no
  directory scan, no identity analysis, no append, and no writes.

Focused GREEN-0 tests may assert help text, unknown subcommand, unknown option,
`--canonical`/`--global` conflict, missing `reconcile --source`, JSON report
schema/status, nonzero exits, and byte-identical canonical/source fixtures.
All scanner, classifier, identity, drift, conflict, redaction, append, and
idempotency tests must remain RED after this skeleton.

### RED-1 — behavioral reconciliation contract

After GREEN-0, rerun the full telemetry test file. RED-1 must show multiple
named behavioral assertion failures with `0 errors`; it must no longer be a
top-level unknown-command failure. A fresh RED review then reads Plan 34 and
the tests only, including the prior RED findings below, before any scanner or
mutation code lands.

### GREEN-1 — implementation

Only after RED-1 passes review may implementation add canonical/source reads,
classification, identity comparison, reports with real counts, and locked
append. Keep the first scanner/append commit separate from GREEN-0 so the
skeleton cannot absorb production behavior.

Required behavioral cases for RED-1:

1. clean mixed-era canonical stream passes;
2. malformed canonical JSON fails;
3. duplicate v2 start/end identity fails;
4. v2 end with no/mismatched start fails; unpaired start passes;
5. absent source rich row makes assert and reconcile dry-run fail without write;
6. apply appends one row and a second apply is a no-op;
7. identity conflict blocks the entire batch and leaves bytes unchanged;
8. equivalent ISO offsets deduplicate legacy identity;
9. source directory excludes canonical, `.git`, and symlinks and ignores
   unrelated JSON;
10. a directory source containing a generic JSON summary with `meta.id`,
    `meta.started_at`, and `actual`, but without the required harnex
    rich-summary section evidence, is ignored and does not produce drift or
    conflicts;
11. JSON report is bounded and contains no marker secrets placed in payloads;
12. CLI help/unknown subcommand/option errors follow existing conventions.

Run only the new test file for each RED stage. RED must be behavioral, not a
syntax/fixture failure.

## Phase 3 — RED contract review

A fresh reviewer reads Plan 34 and the new tests only. It must confirm the tests
fail for missing production behavior and prove zero-write/idempotency/conflict
contracts. No production implementation until verdict is pass.

## Phase 4 — Implementation and docs

Expected bounded surface (names may adjust to existing conventions):

- `lib/harnex/telemetry_reconciler.rb` — parsing, classification, identity,
  analysis, locked append, report;
- `lib/harnex/commands/telemetry.rb` — subcommand/options/rendering;
- `lib/harnex.rb` and `lib/harnex/cli.rb` — requires/routing/help;
- `test/harnex/telemetry_reconciler_test.rb` — RED tests;
- `docs/dispatch-telemetry.md` and `CHANGELOG.md` — operator contract;
- issue/plan resolution notes after review.

Prefer pure functions over a generic framework. Keep new production code near
300-450 lines and total diff under roughly 850 lines including tests/docs.

Validation:

```bash
ruby -Ilib -Itest test/harnex/telemetry_reconciler_test.rb
ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'
git diff --check
```

Then run an actual temp-repository CLI smoke: mixed canonical + one missing
legacy rich source → assert fails → dry-run leaves bytes unchanged → apply adds
one → assert passes → second apply leaves bytes unchanged.

## Phase 5 — Independent code review

Review Plan 34, Issue 67, and the bounded diff. Focus on data-loss/duplication,
TOCTOU under the append lock, source false positives, report leakage, and CLI
exit contracts. Reviewer does not run tests. Any P1/P2 finding gets a focused
fix and rereview; P3 may be documented if truly non-contractual.

## Phase 6 — Patch release and Holm handoff

After code review passes and the owner confirms publish:

1. bump to `0.10.1`, update changelog/issue/plan/state;
2. run the full suite at release HEAD;
3. build and publish using `bin/gem-push` (never read `.env` directly);
4. tag/push and `gem install harnex`;
5. verify `harnex --version` and run the installed-binary temp-repo smoke;
6. write `koder/releases/0.10.1.md`; remove the built gem.

The implementation dispatch itself is the missing real-Codex smoke for
`0.10.0`; record that fact, but do not claim the new command is installed until
the post-publish smoke passes.

Then Holm gets a separate, tiny integration change:

- a tested wrapper calls installed `harnex telemetry assert-canonical
  --source koder/scratch`;
- `scripts/session/close.sh --commit-docs` runs it after the scratch gate and
  before consuming `SESSION_OPEN.json`;
- failure blocks close with an actionable reconcile command;
- no automatic reconcile or source deletion occurs during close.

## Depth bounds

- **Prior digestion:** Issue 67 and this plan encode the decisions. Do not
  re-derive the mirror incident or redesign dispatch telemetry.
- **Read budget:** plan review <=8 files; RED tests <=8 files; implementation
  <=12 files plus this plan/issue; code review <=10 files.
- **Output ceiling:** plan-review verdict <=180 lines; tests+implementation diff
  <=850 lines; review <=180 lines. Final worker summary <=30 lines.
- **Override path:** stop with one concrete blocker if current source cannot
  support one-lock append, the classifier cannot distinguish rich rows without
  consumer-specific knowledge, or the expected diff exceeds the ceiling. Do
  not broaden into schema migration or telemetry redesign.
- **Verified-state reporting:** implementation/test workers run `git diff
  --stat` after edits and report only command-verified file/test state, listing
  every validation command and result.

## Plan review corrections

- P1-1: v2 identity is `(session_id, id, normalized started_at UTC instant)`;
  `session_id` cannot replace dispatch ID plus start instant, and v2/legacy
  cross-family recovery matches only on `id`, normalized `started_at`, and
  semantic payload equality.
- P2-1: directory recovery accepts only rich dispatch end records, with legacy
  envelope-less summaries requiring `meta`, `actual`, and at least two known
  harnex rich-summary section keys; generic summaries are ignored.
- P3-1: envelope-less rich recovery is described as new reconciler behavior,
  not behavior already accepted by current `harnex history` readers.

## RED review staging correction

Verdict: fixed for planning. P1/P2/P3 open count: 0.

- Prior RED P1-1 maps to RED-1: add an assertion where two valid v2 start/end
  pairs share one `session_id` but have different `id` and/or normalized
  `started_at`, and `assert-canonical --json` is clean with counts proving both
  pairs survived independently.
- Prior RED P2-1 maps to RED-1: make canonical exclusion and symlink pruning
  observable with distinct would-be source candidates, not just an already
  present row or a deduplicated identity.
- Prior RED P3-1 maps to GREEN-0/RED-1: pin an unknown telemetry option through
  the same parse-error convention as other commands.

## Definition of done

Issue 67 is done when `0.10.1` is installed, its command pair passes the real
recovery/idempotency smoke, Holm close invokes the read-only assertion before
session-ledger mutation, both repositories are clean/pushed, and no source
mirror or historical migration path has been reintroduced.

## Release completion

Completed 2026-08-04. `0.10.1` is published, tagged, installed, and verified;
see `koder/releases/0.10.1.md`. The installed command passed actual legacy-rich
and v2 recovery/idempotency/conflict smokes plus a real Codex dispatch. Holm
Plan `722` wired `assert-canonical --source koder/scratch` into close after the
scratch gate and before session-ledger mutation; runtime ordering tests and
independent review passed. No mirror, automatic apply, source cleanup, or
historical rewrite was introduced.
