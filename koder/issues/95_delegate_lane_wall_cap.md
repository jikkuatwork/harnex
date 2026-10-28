---
status: open
priority: P2
created: 2026-10-29
updated: 2026-10-29
tags: delegate, timeout, caps, unattended, orchestration
type: feature
related: 86, 94
---

# Issue 95 — `delegate` has no lane wall cap; `--timeout` only bounds the caller's wait

## What happened (Holm, 2026-10-29)

Holm's class-lane workflow assumed `harnex delegate --no-wait --worktree NAME --timeout 60m`
caps the lane at 60 minutes. The help says otherwise: `--timeout DUR` is "Wait at most DUR …
On 124 the worker keeps going". With `--no-wait` it bounds nothing. On 2026-10-28 a test-speed
lane ran 111 minutes against a 60-minute cap because nothing enforced it, and the orchestrator
that should have stepped in was paused by its own usage window.

## Ask

A mechanical per-lane wall cap that survives the orchestrator: for example
`delegate --cap 60m [--cap-grace 15m]`. At the cap harnex sends the worker one fixed message
("cap reached: commit what is green and reply STOP: cap"); after the grace it stops the worker,
keeps the worktree and branch, and settles the lane as `capped` (distinct from `failed`), shown
in `lanes` and `lanes --json` with the cap and the elapsed wall. Continuations (`reply`) count
against the same cap unless `--cap` is passed again.

## Why in harnex

Every project running unattended lanes needs it, and an orchestrator-side heartbeat cannot
enforce a cap while the orchestrator itself is paused or dead (the case that triggered this).
Holm enforces caps from its heartbeat until this ships.
