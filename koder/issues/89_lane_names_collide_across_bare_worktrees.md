---
status: resolved
priority: P2
created: 2026-10-23
updated: 2026-10-25
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

## Second observation (2026-10-24 ~00:46, same night)

A `gpt` relay given only `cwd:` + `mode: write` headers (no `worktree:`) for a brief that said
"in the sibling worktree /home/…/night-1024_s3_fix (branch night/1024_s3_fix)" named the lane
`night-1024_s3_fix` and also created an empty harnex worktree,
`<cwd>/.harnex/worktrees/night-1024_s3_fix` on `harnex/night-1024_s3_fix` (0 commits); the worker
itself worked and committed in the cwd as asked. The relay (a small model) appears to infer
`worktree` from brief prose. Suggested fix: `agents/gpt.md` never sets `worktree` unless a
`worktree:` header line is present, and `delegate` refuses `worktree` when `cwd` is itself a
linked worktree of the same repo.

## More evidence (Holm Queue 167, 2026-10-24/25)

Names also collide **within one checkout** when briefs open alike. Three different planning
lanes (an MCP design check, a Spaces plan and a proposal draft, each in its own sibling worktree)
all became `pi-are-planning-lane-holm`, and two research lanes became
`pi-are-reviewing-external-*`. The orchestrator worked only because the `gpt` relay keeps one
agent per lane, so follow-ups reached the right worker. `harnex result <name>` and
`harnex lanes` were ambiguous. Suggest folding in a short random or role-plus-path suffix, or
letting the caller pass a name (a `name:` header key for the `gpt` agent).

## Resolution (0.30.0, 2026-10-25)

- `Lanes.main_root` treats a bare layout as one repo: the main checkout is the
  worktree on the bare repo's `HEAD` branch (`holm/master`), so every sibling
  worktree shares one lane namespace and `harnex lanes` shows them all.
- A lane *in flight* (running or uncollected, or a worktree lane not yet
  landed) holds its name across every repo: generated names skip it, and
  `delegate --name/--worktree` and `ask --id` refuse it. `resolve` prefers
  the in-flight lane, so `result NAME` / `reply NAME` work from anywhere.
  Settled in-place lanes (which stay open for `reply`) do not lock names
  elsewhere, and a lane whose repo is gone holds nothing.
- Generated names: a lane in another worktree is named after it
  (`pi-night-1024_s3`); "are", "carry", "out", "brief", "lane" and single
  letters are filler, so "You are a build lane in Holm's …" no longer names it.
- `delegate --worktree` refuses a `--cwd` that is already another worktree.
- `agents/gpt.md`: tool arguments come only from header lines (never
  `worktree` from prose); new `name:` header; `cwd:` is passed to `result`
  and `reply`. MCP `ask` takes `name`.
- Footer step 4 (`--cwd` in hints) was not needed: in-flight names are
  unique, so the printed `harnex result NAME` works from any directory.
