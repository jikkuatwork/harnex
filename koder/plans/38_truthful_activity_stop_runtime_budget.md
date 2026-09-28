---
status: in_progress
issue: 71
plan: 38
layer: unattended-completion-reliability
created: 2026-09-28
updated: 2026-09-28
---

# Plan 38 — Truthful activity, stop provenance, runner runtime budget

Owner authorized #69/#71 completion and local install only. Build on Plan 36;
Plan 37 owns wait/watch observer hardening. Preserve Plan 35 notifications.

## Scope and sequence

1. Track structured turn/model/tool activity with monotonic elapsed clocks and
   bounded timestamps. UI/status/log output must not advance work clocks;
   thinking deltas count as activity without retaining thinking text. PTY or
   otherwise unobserved model/tool progress is unknown.
2. Add bounded typed stop reason/origin through stop CLI/API, events, receipt,
   status and dispatch-end telemetry. First stop provenance wins. Expected idle
   cleanup stays distinct from interrupted work and from genuine transport loss.
3. Add `run --max-runtime DUR`, armed in the runner before the initial prompt,
   independent of watchers, retries and UI activity. Expiry requests a typed
   runtime-budget stop with bounded TERM/KILL escalation, preserves prior settled
   proof, and fails active work. Do not reset the budget on progress or retries.
4. Expose a capability/version check and document runtime versus observer caps,
   truthful clock limits, and Pi steering as queue acceptance—not consumption.

## Proof

- RED/unit tests for UI-only churn, model/thinking/tool events, quiet active work,
  unknown PTY progress, immutable stop provenance and privacy-safe payloads.
- Regression tests preserve Plan 36 idle cleanup and fail closed for busy stops.
- Runtime expiry works with no supervisor, including a stuck abort request;
  completion/expiry races have one coherent terminal result and notification.
- CLI equal/separate forms, tmux forwarding, invalid budgets and capability checks.
- Full suite, independent review, real Pi lifecycle smoke, synthetic budget and
  heartbeat/deadline smokes against the locally installed new gem.

## Closeout

Update #69/#71 with exact evidence, all three plans, CHANGELOG and a release
verification record including skipped/non-covered tests. Install a new version
locally without rebuilding/replacing retained 0.13.0 or publishing anything.
No consumer wake queue, automatic first-write kill, scheduler, retries policy,
or Pi command-exit observation expansion is in scope.
