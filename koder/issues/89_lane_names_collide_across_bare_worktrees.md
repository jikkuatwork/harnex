---
status: open
priority: P2
created: 2026-10-23
updated: 2026-10-23
tags: lanes, naming, worktrees, agents, mcp
type: bug
related: 86, 87
---

# Issue 89 — Lane names collide across worktrees of a bare repo, and `result NAME` then fails

Seen 2026-10-23 23:45 in Holm (harnex 0.29.1). Three `gpt` agents launched at once, each with
`cwd:` set to its own sibling worktree (`../night-1023_s3_objects`, `../night-1023_analytics_plan`,
`../night-1023_postgres_map`) and briefs that all open "Read and carry out the brief at …". All
three lanes got the same generated name, `pi-read-carry-out-brief`.

Why (from source):

- `Lanes.main_root` returns the main checkout only when the common dir is named `.git`. Holm uses
  a `.bare` layout (`holm/.bare` + sibling worktrees), so each worktree falls through to
  `--show-toplevel` and counts as its own repo.
- `generate_name` only de-duplicates within that root, so identical briefs in sibling worktrees
  get identical names (in a `.git` layout they would get `-2`, `-3`).
- `Lanes.resolve` tries the caller's repo, then "the only lane anywhere with that name"; with three
  matches it raises `several lanes are named "pi-read-carry-out-brief" (…); run from the lane's repo`.
- `agents/gpt.md` passes `cwd` to `delegate`/`ask` but not to `result` or `reply`. Its harnex MCP
  server runs from the session's cwd (master), so once a lane outlives the 25-minute delegate
  wait, the relay's `result` call hits the error above. `harnex lanes` from master also hides the
  three lanes (only `--all` shows them).

The workers are unaffected; the caller can still collect with `result --cwd <worktree>`.

Suggested fix (owner's suggestion first):

1. **Refuse duplicates:** `delegate --name X` is refused while another open lane anywhere is
   named X, and generated names de-duplicate against every open lane, not just this root.
2. Key a bare-repo layout by its common dir, so every worktree of one repo shares a lane
   namespace and `harnex lanes` from any of them shows all of them.
3. `agents/gpt.md`: carry the `cwd:` header into `result` and `reply`; accept a `name:` header
   and pass it to `delegate` so callers can name lanes (`s3`, `an`, `pg`).
4. Footers and the `lanes` NEXT column print a step that works from anywhere
   (`harnex result X --cwd <dir>` when the lane's repo differs from the caller's).

Acceptance: three concurrent `gpt` agents with identical briefs in three sibling worktrees of a
bare repo get three distinct names, and each relay's `result` collects its own lane.
