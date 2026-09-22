---
status: open
priority: P1
created: 2026-09-22
updated: 2026-09-22
tags: telemetry, history, locking
type: feature
issue_kind: slice
---

# Issue 73 — Make dispatch history safe for external archival

Harnex currently locks the opened `.harnex/dispatch.jsonl` inode and every
reader assumes that file contains all historical rows. Atomic rotation can
therefore strand a waiting append on the old inode, while trimming old rows
would make history, attempt-chain accounting, and canonical reconciliation
silently incomplete. Use a stable sidecar lock before opening the ledger, add
an opt-in local executable protocol that may prepare room before each append,
and let canonical readers consume an opt-in complete-history JSONL stream.
Archive-helper failure must retain the new row in the active ledger and report a
bounded warning; malformed or unavailable complete history must fail explicitly.

Acceptance: focused writer concurrency and external-reader tests pass, existing
history/status/reconciliation semantics remain green, the full Ruby suite
passes, and the change has no network behavior unless an operator explicitly
configures a local helper executable.

Source exposure: none — implementation and tests stay local and use synthetic
JSONL; the protocol invokes only an explicitly configured local executable.
