---
status: open
priority: P2
created: 2026-10-25
updated: 2026-10-25
tags: lanes, worktrees, land, holm
type: feature
related: 89, 86
---

# Issue 90 — Let lane worktrees live beside the main checkout

Seen in Holm (harnex 0.29.1), Queue 167, night of 2026-10-24.

`delegate --worktree NAME` creates `<checkout>/.harnex/worktrees/NAME` on branch `harnex/NAME`,
and `land` merges it. Holm's rule (owner, 2026-10-16) is that every worktree is a **sibling of the
master checkout** (`../<slug>`), never inside it. So Holm can't use `--worktree`, `land`, or the
`gpt` agent's `worktree:` header. Holm Issue 1050 records the owner's decision to keep the rule.

Tonight's workaround for every build lane:
- `git worktree add ../night-1024_<slug> -b night/1024_<slug>` by hand;
- `gpt` agent with `cwd: ../night-1024_<slug>` and `mode: write`;
- a manual `merge:` commit, `git worktree remove` and `git branch -d`.

It worked, but `land`'s merge and cleanup and the lane's knowledge of its own worktree were lost.

Ask: a worktree location option, for example a config key `lanes.worktree_root: "../"` (relative
to the main checkout) or `--worktree-path ../<slug>`, used by `delegate --worktree` and honoured
by `land` and `discard`. Branch naming should be configurable too (Holm uses `night/<date>_<slug>`
for queue rows). With Holm's `.bare` layout, "main checkout" means the `master` worktree; see
Issue 89 for how `main_root` resolves there.
