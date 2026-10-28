---
status: open
priority: P2
created: 2026-10-28
updated: 2026-10-28
tags: lanes, land, discard, ask, cleanup, orchestration
type: feature
related: 89, 90, 93
---

# Issue 94 — Settled lanes linger after a manual merge; `land` cannot clear them

## What happened (Holm, 2026-10-28)

Holm merges lane branches by hand (`git merge --no-ff -m "merge: …"` from master) and
removes the worktree and branch itself, as its workflow requires. Afterwards:

1. `harnex lanes` kept listing 25 settled lanes from the last two days, each with a
   `NEXT` of `harnex land NAME` (delegate lanes) or `harnex reply NAME "..."` (ask lanes).
2. `harnex land q174-a8-secrets` answered `not landed — could not merge
   night/1028_q174-a8-secrets … not something we can merge` (exit 0), because the branch
   was already merged and deleted. The suggested next step can never succeed.
3. `harnex discard q174-a8-secrets` did clear the record ("removed its worktree and
   branch"), but its name says "drop the work", so an orchestrator under the rule
   "never discard unmerged work" hesitates to use it for merged work.
4. Collected `ask` lanes never leave the table; their only `NEXT` is a follow-up reply.
5. `lanes --json` returns every lane ever recorded (about 170 here), while the table
   shows only recent ones; a script that iterates the JSON to tidy "settled lanes"
   touches history it did not mean to.

## Wanted

- **`land` recognises an already-merged lane.** When the lane's branch is gone or its
  last commit is an ancestor of the current branch, `harnex land NAME` reports
  "already merged" and removes the lane record (and any leftover worktree); it does not
  suggest itself again.
- **A neutral clear verb for settled lanes**, e.g. `harnex ack NAME` or `harnex land
  --merged NAME`, so clearing merged work never reads as discarding it.
- **Collected `ask` lanes expire from the table** once their result has been read, or
  after a configurable age; `lanes --all` keeps the history. The JSON should carry the
  same scope as the table by default, with `--all` for history.
- The footer of a settled lane names the verb that actually clears it.

## Not in scope

Changing Holm's manual-merge rule, or any automatic merge.
