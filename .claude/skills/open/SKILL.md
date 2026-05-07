---
name: open
description: Open a work session in this repo — read koder/STATE.md first, inspect the current worktree, align on the active issue or plan, and establish the starting point before editing. Use when the user says "open session", "start work", "initialize", "orient yourself", or invokes "/open".
---

# Open Session Workflow

When the user asks to initialize or open the session, run this sequence:

## 1. Read the handoff

- Read `koder/STATE.md` first
- Note the `Past`, `Present`, and `Future` handoff sections
- Open only the issue or plan files relevant to the current task

## 1a. Token discipline — issues and plans

Do **not** read every file under `koder/issues/` or `koder/plans/`.
Acquire meta only:

- `ls koder/issues/ | wc -l` for a count
- `ls koder/issues/` for the list of names — names are
  self-describing (e.g. `35_dispatch_telemetry_hygiene.md`)

Then read **only** the one STATE.md names as the current focus or
next step. Read others on demand: when the user references one, when
work in progress requires it, or when triaging.

Same rule for `koder/plans/`. Same rule for `koder/releases/` —
durable records, only read the specific one referenced.

## 2. Inspect the repo state

- Run `git status --short`
- Notice modified or untracked files before editing
- Do not revert unrelated changes you did not make

## 3. Establish the starting point

- Summarize the important context for this session: relevant issue or plan, repo state, and the immediate next step
- If the user already asked for implementation, continue into the work instead of stopping at orientation
- Update `koder/STATE.md` during open only if it is clearly stale enough to mislead the session

## Notes

- Treat `koder/STATE.md` as the handoff document between sessions
- Keep `koder/STATE.md` thin; durable history belongs in `CHANGELOG.md`
- Prefer updating existing issue or plan docs over creating new tracking files
- Do NOT create issue docs unless the user explicitly asks
