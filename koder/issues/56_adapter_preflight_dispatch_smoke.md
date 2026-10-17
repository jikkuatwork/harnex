---
status: resolved
priority: P1
issue_kind: slice
created: 2026-07-15
updated: 2026-10-18
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

- [x] One command exercises boot, registration, task read, workspace write,
      command execution, typed report ingestion, completion, and stop for a
      named adapter in a named cwd.
- [x] Trust prompts, registration timeouts, sandbox read/write denials, and
      missing receipts each produce a distinct failing check, not a generic
      failure.
- [x] Telemetry capability (usage/cost/context) is reported per adapter with
      provenance status, never silently absent.
- [x] The preflight row lands in dispatch history and is excluded from
      throughput/cost rollups by default.
- [x] Docs recommend running preflight for the chosen adapter plus one declared
      fallback adapter before any unattended queue run, noting that both must
      be inside the caller's dispatch-model policy (out-of-policy adapters are
      launch blockers, not fallbacks).

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

## Resolution

Implemented 2026-10-18 as `harnex preflight ADAPTER [--cwd DIR]
[--task-root DIR] [--commit-check] [--timeout DUR] [--registration-timeout DUR]
[--model NAME] [--effort LEVEL] [--legacy-pty] [--] [cli-args...]`
(`lib/harnex/commands/preflight.rb`).

- Drives the real `harnex run ADAPTER --detach --auto-stop` path in a child
  process with a numbered prompt: read a pinned task file from the task root
  (default `/tmp`, where queue task files usually live), write its token into
  `<cwd>/.harnex/preflight/<id>.txt`, run an exact `echo` gate command
  (declared with `--final-gate`, so its exit comes from harness observation),
  write claims to `$HARNEX_ARTIFACT_CLAIMS_PATH`, and reply DONE.
- Verdict `harnex.preflight.v1`: checks `registration`, `boot`, `permission`
  (blocking trust/confirmation prompt for ≥15s), `task_read`,
  `workspace_write`, `command_exit` (`unsupported` for PTY transports),
  `receipt`, `claims`, `completion`, `stop`, plus `commit` with
  `--commit-check` (second dispatch in a throwaway scratch repo). The first
  failing check names `failure`; a failed completion uses the #57 outcome class.
  A turn that fails before any work (auth/model errors) skips downstream checks
  and reports the redacted error.
- `telemetry` reports `usage`, `cost` (`observed` when provider-reported,
  `estimated` from price table/caller, else `unsupported`) and `context`
  provenance; `unavailable` when no row exists. Never absent.
- The dispatch row carries `phase=preflight` (exempt from a repo phase
  allowlist, since Harnex owns that phase); `orchestration report` excludes
  such rows unless `--include-preflight`. Task and workspace files are removed;
  the row stays as history.
- Workers cannot be orphaned: stops go straight to the session API (works for
  `--cwd` subdirectories), the run carries a `--max-runtime` backstop of
  registration + timeout + 60s, and an `ensure` stops any still-registered
  worker. Launch errors (bad config, missing binary) report `launch_failed`,
  distinct from `registration_timeout`; a timeout or blocking prompt skips the
  downstream checks instead of blaming the workspace.
- Docs: `guides/01_dispatch.md` recommends preflight for the chosen adapter
  plus one declared fallback, both inside the dispatch-model policy.

Verification: hermetic tests with an obedient/misbehaving Codex app-server stub
(`test/harnex/commands/preflight_test.rb`: pass path, write denial, read
mismatch, missing claims, auth-failed turn, timeout + stop, missing binary,
commit check, usage errors, rollup exclusion). Live on this machine (checkout):
`harnex preflight pi` passed all checks in 57s with observed usage/cost/context;
`--commit-check` passed (caller repo untouched). `harnex preflight codex`
correctly failed in ~20s with `task_failed` (OpenAI `401 invalid_api_key` in
the local Codex configuration), so a live Codex pass and the live Codex
command-string shape remain unverified here.
