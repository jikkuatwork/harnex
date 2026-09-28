---
status: in_progress
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
