---
status: open
priority: P1
issue_kind: slice
created: 2026-07-15
updated: 2026-07-15
tags: preflight,adapter,readiness,doctor,unattended,queue
---

# Issue 56 — Adapter preflight dispatch smoke before unattended runs

## Problem

`harnex doctor` validates static prerequisites (Codex CLI version, optional
session-drift sweep). It does not prove that a specific adapter can actually
complete a dispatch in a specific working directory.

SDK Queue `#002` (14–15 Jul 2026, `~/Projects/holmhq/sdk`,
`koder/analysis/001_q002_orchestration_efficiency/INDEX.md` at `4ebd7f1`)
discovered adapter unreadiness only by burning live dispatches:

- Codex app-server could not read task roots under `/tmp` in its sandbox;
- after moving runtime controls, the app-server workspace was still read-only;
- Codex legacy PTY first missed Harnex registration within the default
  timeout, then hit a workspace trust prompt and disconnected without receipts;
- 7 of 25 dispatches ended with no proof, and 4 of 6 coordinator sessions
  existed only to recover from adapter churn (~1.5h of an overnight window).

Every one of these is detectable in under two minutes with a trivial task.

## Goal

A `harnex preflight ADAPTER [--cwd DIR] [--commit-check]` command that runs one
tiny end-to-end dispatch and emits a JSON verdict:

1. boot and Harnex registration within the configured timeout;
2. read a pinned task file from the resolved task root;
3. write a file inside the workspace;
4. execute a shell command and capture its exit;
5. emit a typed artifact report that Harnex ingests;
6. signal completion and stop cleanly (`--auto-stop` path);
7. with `--commit-check`, create and verify a throwaway commit in a scratch
   repo (never the caller's repo);
8. report telemetry capability per field: `usage`, `cost`, `context` each as
   `observed | estimated | unsupported`, reusing plan-31/#54 provenance vocab.

Nonzero exit when any required capability fails, so orchestrators can gate an
unattended launch on `preflight && run`. The verdict row should be written to
dispatch history like any other dispatch, flagged `phase: preflight`.

## Acceptance criteria

- [ ] One command exercises boot, registration, task read, workspace write,
      command execution, typed report ingestion, completion, and stop for a
      named adapter in a named cwd.
- [ ] Trust prompts, registration timeouts, sandbox read/write denials, and
      missing receipts each produce a distinct failing check, not a generic
      failure.
- [ ] Telemetry capability (usage/cost/context) is reported per adapter with
      provenance status, never silently absent.
- [ ] The preflight row lands in dispatch history and is excluded from
      throughput/cost rollups by default.
- [ ] Docs recommend running preflight for the chosen adapter plus one declared
      fallback adapter before any unattended queue run.

## Out of scope

- Security sandboxing guarantees (`--cwd` remains a selector, not a jail).
- Model quality evaluation; this proves plumbing, not reasoning.
- Automatic adapter selection (callers read the verdict and decide).

## Relationship to existing work

- Extends `harnex doctor` (static checks) with a dynamic dispatch smoke.
- Failure classes should align with #57's terminal outcome taxonomy.
- #42 (app-server recovery) reduces the blast radius after launch; preflight
  prevents launching into a known-broken configuration at all.

## Triage

- **Tier**: B (plan → impl → verification).
- **Risk**: low; composes existing run/wait/report primitives.
- **First useful slice**: preflight for `pi` and `codex` app-server with task
  read/workspace write/report ingestion checks and a JSON verdict.
