---
status: resolved
priority: P3
created: 2026-10-25
updated: 2026-10-25
tags: lanes, footer, telemetry
type: bug
related: 87
---

# Issue 91 — A lane footer's commit count includes other people's commits

Seen in Holm (harnex 0.29.1), 2026-10-24/25. Research lanes told "do not commit" ran in place in
the master checkout while the orchestrating Claude session made its own commits there. Their
footers reported, for example, `· 6 commits, 5 files (+548 -4)` and `· 7 commits, 7 files
(+751 -5)`. `git log` showed the worker had made **none**: the count was HEAD movement in the
window, all from the orchestrator. It cost a verification detour each time ("did the worker break
its no-commit rule?").

Ask: count only commits created by the worker's process (for example commits whose author time
falls in the lane window *and* that are reachable only through the worker's own `git commit`
calls, or the worker's reported commits), or label the number as "repo HEAD moved by N
commits", and keep files and line counts to the worker's own diff.

## Resolution (0.30.0, 2026-10-25)

The session reads `HEAD` around each worker command that mentions `git`;
commits that appear during one are emitted as `worker_commits` events (and the
`git` start event says `tracks_worker_commits`). For a lane without a worktree
the footer counts only those commits still in history, with files and lines
from their own diffs, and names the rest: `0 commits (HEAD also moved 6
commits by others)`. Lanes run by older harnex keep the old count. Worktree
lanes are unchanged (their branch is the worker's alone).
