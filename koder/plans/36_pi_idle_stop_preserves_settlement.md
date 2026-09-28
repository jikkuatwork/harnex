---
status: completed
implementation_review: approved
issue: 69
plan: 36
layer: unattended-completion-reliability
created: 2026-09-28
updated: 2026-09-28
---

# Plan 36 — Preserve Pi settlement through operator cleanup

Owner authorized solving #69/#71 and a local-only new-version install. No public
publication, tag, push, model-policy change, or credential workaround is included.

## Scope

Fix `koder/issues/69_pi_stop_after_settled_receipt_rewrite.md`: explicit idle stop
must preserve the latest accepted or no-change turn, while busy stop and genuine
transport loss remain failures. Do not confuse process teardown with acceptance.

## Execution

1. Add RED regressions for one/two accepted turns then idle stop, newer busy turn
   then stop, unexpected disconnect, and finalization idempotence.
2. Make the smallest session/adapter lifecycle fix. Synchronize dispatch, terminal
   callbacks, and stop decisions; keep raw child status observable.
3. Verify final receipt, end-row reliability, registry cleanup, and existing
   auto-stop behavior. Commit reviewed code/tests independently of Plan 37.
4. Integrate before Plan 38's stop-provenance/runtime changes. Run independent
   review and installed-binary two-turn proof before closing #69.

## Acceptance

- Accepted/no-change proof survives explicit idle cleanup, including two turns.
- No false lost adapter/disconnection classification for expected cleanup.
- Busy stop cannot accept an older turn or a late successful callback.
- Unexpected exits/malformed transport remain failures; one coherent end row.
- Focused/full suites and a real local persistent-Pi smoke pass.

Stop rather than broadening into Pi command-exit observation (#70), PTY support,
or a second notification queue. Related layer plans: 35 (shipped), 37, 38.

## Delivery

Completed in local 0.14.0, package source `aab0973`. All acceptance checks passed,
including the installed two-turn Pi 0.87.1 idle-stop proof, 3.2s gated receipt,
and independent final review at `78d3efa`. Full suite: 815 runs / 3,820 assertions,
no failures/errors. Evidence and non-coverage: `koder/releases/0.14.0.md`.
