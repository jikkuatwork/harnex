---
id: 17
title: "Multi-Session Coordination — Parallel Supervisors & Cross-Worktree Awareness"
status: open
priority: P1
created: 2026-03-29
---

# Issue 17: Multi-Session Coordination

## Problem

When multiple Claude/Codex supervisor sessions operate in the same repo (or
across worktrees), harnex has gaps in coordination, discovery, and messaging
that make the workflow fragile.

### Current State

1. **Same-repo concurrency works** — different session IDs get separate
   registry files, ports, and tmux windows. No technical collision.

2. **Cross-worktree isolation is total** — `git rev-parse --show-toplevel`
   returns the worktree path, so each worktree gets a different `repo_hash`.
   Sessions in different worktrees are invisible to each other by default.

3. **send/pane asymmetry** — `harnex pane` has a global fallback (searches
   all repos if local lookup fails, uses the match if exactly one exists).
   `harnex send` does not — it requires explicit `--repo` to reach a session
   in a different worktree. You can watch an agent you can't message.

4. **No supervisor scoping** — `harnex status` shows all sessions in a repo
   but doesn't indicate which supervisor spawned which agent. Two supervisors
   see each other's agents with no ownership context.

## Sub-Problems (split for implementation)

### A. Fix send/pane asymmetry

`send` should have the same global fallback as `pane`: if the target ID isn't
found in the current repo and `--repo` wasn't explicit, search globally and
use the match if exactly one exists. This is the most concrete fix.

### B. Session namespacing convention

Define a convention for namespaced session IDs so multiple supervisors don't
collide. Something like `<supervisor>-<role>-<plan>`:

```
a-cx-impl-42    # supervisor A, codex implementer, plan 42
b-cl-rev-43     # supervisor B, claude reviewer, plan 43
```

This is a convention/docs change, not a code change. Update the dispatch skill
to recommend namespacing when multiple supervisors are active.

### C. Supervisor ownership metadata (optional)

Consider adding a `spawned_by` field to the session registry — the parent's
`HARNEX_ID` or a user-provided supervisor name. This would let `harnex status`
group sessions by supervisor. Low priority — namespaced IDs may be sufficient.

### D. Evaluate worktree complexity vs. value

Worktrees add real isolation (separate git index, parallel branches) but
introduce coordination overhead:
- Cross-worktree messaging requires `--repo` (or fix A above)
- Merge conflicts on `koder/` state files (STATE.md, plans, reviews)
- Supervisor must track session-id → worktree-path mapping
- Worktree deletion while session is active leaves orphaned registry entries

**Open question**: Is worktree isolation worth the complexity? For serial work
on master with namespaced IDs, most benefits of worktrees (no staging conflicts)
don't apply. Worktrees earn their keep only for parallel commits on different
branches — which may not be the common case.

If worktrees are kept, document the merge workflow clearly in the dispatch skill:
1. Stop session before merging
2. Merge from master, keep master's STATE.md on conflict
3. `git worktree remove` + `git branch -d`

### E. `harnex status --all` improvements

When showing cross-repo sessions, group by git common dir (so worktrees of the
same repo are visually grouped). Currently they appear as unrelated repos.

## Implementation Notes

- Start with **A** (send fallback) — smallest, most concrete, highest value
- Then **B** (namespacing docs) — convention change, no code
- **C** and **E** are nice-to-haves
- **D** is a design decision that should be made before investing more in
  worktree support

## Related

- Issue 14: pane lookup bugs (added the global fallback for pane)
- Dispatch skill: worktree section documents current caveats
