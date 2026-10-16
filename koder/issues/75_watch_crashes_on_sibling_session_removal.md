---
status: resolved
priority: P2
created: 2026-10-15
updated: 2026-10-16
tags: watch, observer, robustness
issue_kind: slice
type: bug
---

# Issue 75 — `harnex watch` crashes when a sibling session is stopped

## What happened

Holm Queue 156 (2026-10-15 ~22:30 +04), harnex 0.14.1. Several sessions ran in one repo, each
with its own `harnex watch --id <id> --until done --max-wait 90m`. Stopping one finished session
(`harnex stop --id pi-q156-rev903`) made the watcher for a *different*, still-busy session
(`pi-q156-r1b`) exit 1:

```
harnex: harnex wait observer: Errno::ENOENT: No such file or directory @ rb_sysopen -
  ~/.local/state/harnex/sessions/df14c27f6d9f877c--pi-q156-rev903.json
```

The watched session kept running; only the observer died. An unattended supervisor reads exit 1
as "work failed", so this can stall or misroute a queue.

## Expected

The observer only fails on its own session. A sibling session file vanishing between directory
listing and read (stop/cleanup race) is skipped, not raised.

## Fix direction

Where the wait observer enumerates or reads session JSON files, treat `ENOENT` on a non-target
session as "gone" and continue. Add a test: two sessions, watch A, remove B's session file
mid-watch, assert the watcher keeps waiting on A.

## Also observed

The stalled session that preceded this (`pi-q156-r1`) showed `model_active: true` with
`model_idle_s` ~1,600 and `tool_idle_s` ~3,000 while `work_state` stayed `running`. `watch` has
no stall exit for that shape; the Holm supervisor now polls `activity.model_idle_s` itself.
A `--stall-after DUR` option on `watch` (exit code distinct from timeout) would make that native.

## Resolution — 2026-10-16

Root cause: `Harnex.active_sessions` (used by every `read_registry` probe in
`wait`/`watch`, `status`, `send`) globbed `sessions/*.json` and then read each
file, rescuing only `JSON::ParserError`. A sibling finalized between glob and
read raised `Errno::ENOENT`, which the private observer process forwarded as a
fatal error. The scan now treats a vanished file as gone (identical to removal
before the glob); `doctor`'s registry sweep got the same guard. `retention`
already handled it.

Tests: a core unit test and an end-to-end `wait --until done` test with a live
target and a sibling whose registry vanishes mid-read. Without the fix the wait
test reproduces the production message (`harnex wait observer: Errno::ENOENT`);
with it the observer keeps waiting (timeout 124, `work_state: running`).

The "Also observed" `watch --stall-after DUR` idea is split into #76.
