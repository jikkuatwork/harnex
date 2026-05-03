---
status: open
priority: P2
created: 2026-05-03
tags: cli,status,monitoring,worktree,orchestration
---

# Issue 26: `harnex status` silently filters by current repo, missing worktree sessions

## Problem

`harnex status` (no flags) only shows sessions whose `repo` matches the current
working directory's repo root. When dispatching to worker sessions in sibling
git worktrees (e.g. parallel candidate impls during a chain experiment), the
orchestrator running from the master worktree sees `No active harnex sessions`
even though sessions are alive and working in sibling worktrees.

This is silently misleading. Nothing in the output suggests sessions exist
elsewhere. The orchestrator must already know to use `--all` or `--repo` to
see them.

## Real incident (holm Plan 385, 2026-05-03)

Holm orchestrator dispatched 4 parallel candidate impls to worktrees
`~/Projects/holmhq/holm/p385-c{1,2,3,4}` and polled from master. After three
of four committed, the orchestrator's `harnex status` (run from master)
returned `No active harnex sessions` — falsely implying all four were done.
The orchestrator briefly declared completion before the user noticed C1 was
still actively iterating. Recovery cost was small (a quick pane sweep), but
the failure mode is dangerous in lights-out overnight runs where there is
no human to catch it.

## Proposed fix (one of)

1. **Default to all-repo visibility** when no sessions exist for the current
   repo, with a one-line note: `(N sessions in other repos — pass --all to see)`.
2. **Always show sessions, group by repo** with the current repo first. The
   repo filter remains explicit via `--repo`.
3. **Loud message when filter is active and finds zero**, e.g.
   `No active sessions in this repo. 4 active sessions in other repos:
   pass --all to view.`

Option 3 is minimal-surface: preserves current default, adds a hint exactly
when the orchestrator most needs it.

## Why this matters

Worktree-based parallel dispatch is becoming the norm for chain experiments
(holm Plan 385 candidate matrix, similar Plan 372 and Plan 380 patterns).
Orchestrators driving the chain from one worktree but spawning workers in
others should not have to remember a flag to see their own children.

## Acceptance criteria

- [ ] `harnex status` from a repo with zero local sessions but active
      sessions elsewhere produces a hint, not a `No active sessions` message
      that implies global emptiness.
- [ ] Test: spawn a session in worktree A, run `harnex status` from worktree
      B (same `.bare`), confirm output mentions the session or hints at it.
- [ ] No behavior change for users who already use `--all` or `--repo`.

## Out of scope

- Replacing the `--repo` filter (it remains useful for narrow status).
- Cross-machine visibility.
