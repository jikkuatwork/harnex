---
status: open
priority: P1
issue_kind: slice
created: 2026-07-15
updated: 2026-07-15
tags: appserver, completion, auto-stop, no-op, queue, reliability
---

# Issue 60 — Ack-only final answers must not satisfy autonomous work or auto-stop

## Problem

Codex app-server can return a polite acknowledgment as its final answer without
executing the delegated task. Harnex currently emits `task_complete`, reports
success, and lets `--auto-stop` terminate the session because it treats turn
completion as work acceptance.

Holm Queue `086`, Plan 654 (`~/Projects/holmhq/holm/master`, 2026-07-15):

- `cx-t-654q86` (`gpt-5.3-codex`, flex) completed in 7s with the final answer
  “Got it—I’ll open that task file and execute exactly what it asks.”
- `cx-t-654q86b` (`gpt-5.3-codex`, fast) repeated the behavior in 6s.
- Both attempts had zero `commandExecution` events, zero Git delta, and no
  artifact report, yet ended `task_complete` / exit 0 and auto-stopped.
- The same file-referenced task executed normally after switching to GPT-5.5.

The model may choose to acknowledge; the harness must not convert an
acknowledgment-only turn into accepted autonomous work.

## Goal

Add a proof-aware completion gate for autonomous dispatches, using structured
signals rather than transcript prose:

1. Classify a final turn with no command/tool execution, no Git/artifact delta,
   and no required report as `completed_no_activity` / `ack_only` (final name
   can align with #57).
2. Do not let `--auto-stop` report successful work completion for that class.
3. Keep the session recoverable for one explicit/automatic `resume`, or stop
   nonzero with the typed no-op outcome so the caller can retry safely.
4. Allow intentional no-change tasks to prove success explicitly through a
   valid artifact report outcome such as `no_change`.

## Acceptance Criteria

- [ ] A Codex app-server turn that returns a final answer with zero commands,
      zero Git delta, and no required report is not `completed_with_proof`.
- [ ] `--auto-stop` does not destroy the only recoverable session before the
      no-op outcome is exposed or one bounded resume is attempted.
- [ ] `harnex watch --until done` returns nonzero (or a distinct documented
      outcome) for unproven no-activity completion.
- [ ] A valid explicit `no_change` report can satisfy a no-delta task without
      requiring fake file edits or commands.
- [ ] Tests cover both flex and fast Codex app-server metadata paths and prove
      the classifier does not parse transcript prose.
- [ ] Guides distinguish agent turn completion from accepted work completion.

## Related

- #50 — process state versus work-level completion (resolved).
- #57 — terminal outcome classes and process-failure budgets.
- #59 — deterministic conveyor runner consumes the outcome.
- #42 — Codex app-server recovery.

## Non-Goals

- Judging semantic quality of completed code.
- Assuming every zero-diff task is a failure; explicit proof can declare
  accepted no-change work.
- Model-specific prompt workarounds as the primary fix.
