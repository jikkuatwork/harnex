---
status: resolved
priority: P1
created: 2026-10-20
updated: 2026-10-20
tags: receipts, dispatch, git, worktree, orchestration
issue_kind: slice
type: bug
related: 64
---

# Issue 80 — Worktree lanes record the `--root` repo's commit, not the lane's

Observed from a Holm overnight orchestrator (Queue 160, 2026-10-20). Holm launches each pi lane
with `--cwd <sibling worktree> --root <master checkout>` so that dispatch rows land in master's
`.harnex/dispatch.jsonl`. Harnex observes git at `repo_root` only
(`lib/harnex/runtime/session.rb` `emit_git_start_event` → `Harnex.git_capture_start(repo_root,
…)`), so the receipt, the dispatch row and acceptance describe the wrong repository:

- `pi-side-1020` ended with `commit_sha 5fd1256e2`, which is a review commit the supervisor made
  on master while the lane ran. The lane's real head was `d828c00a4` on its own branch.
- `pi-fix998-1020` ended with `commit_sha 2f985f2c2` (master's head at launch). The lane's real
  commit was `1495da3da`.
- Supervisor commits on master during a lane can mark that lane "accepted" or "completed with
  proof" for work it did not do.

Want: when `--cwd` and `--root` differ, observe git in the lane's `--cwd` (its own repository or
worktree) for start/end SHA, branch, receipt claims and acceptance. Keep `--root` for where
telemetry rows are written. If both are useful, record both under distinct keys
(`root_commit_sha`, `cwd_commit_sha`), and make the default `commit_sha` the `--cwd` one. #64
(observed-state receipts) is the parent; this is the worktree case it misses.

## Decisions (owner, 2026-10-20) — ready for autonomous implementation

As the issue asks: when the git toplevel of `--cwd` differs from that of
`--root`, observe git in the `--cwd` repository for start/end SHA, branch,
receipt claims, activity and acceptance. `commit_sha` is the lane's; record
`root_commit_sha` alongside it. `--root` still decides where telemetry rows are
written.

## Resolution

Shipped in 0.18.0 (local install). Git is observed in the `--cwd` toplevel
when it differs from `--root`; the end row adds `root_commit_sha`. Live: the
dispatch row credited the lane commit, and the supervisor's master commit was
recorded only as `root_commit_sha`.
