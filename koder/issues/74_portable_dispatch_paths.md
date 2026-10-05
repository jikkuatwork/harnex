---
status: open
priority: P2
created: 2026-10-05
tags: telemetry, privacy, paths
issue_kind: slice
type: bug
---

# Issue 74 — Portable home paths in dispatch telemetry

Dispatch records currently persist absolute user-home paths, and canonical
reconciliation treats equivalent absolute and home-relative representations as
conflicting payloads. Serialize home paths as `~`/`~/...` at the ledger boundary,
including repair appends, without mutating runtime records. Compare equivalent
forms consistently while retaining conflicts for genuinely different paths,
values, identities and outcomes. Existing records are not rewritten automatically.

Acceptance: behavioral RED/GREEN tests cover nested data, home-prefix boundaries,
non-mutation, mixed legacy/current comparisons, append-only repair, idempotency,
absolute status roots and live-artifact retention;
the full Ruby suite passes; local packaging and installed-CLI smoke checks pass.
No remote/model dispatch or public publication is part of this change.

Source exposure: none — local code, synthetic records, private test state and a
local gem only. No product-repository source or identifying policy is copied into
this repository, and no network transfer or live telemetry repair is performed.
