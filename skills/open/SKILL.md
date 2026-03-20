---
name: open
description: Open a work session in this repo — read koder/STATE.md first, inspect the current worktree, align on the active issue or plan, and establish the starting point before editing. Use when the user says "open session", "start work", "initialize", "orient yourself", or invokes "/open".
---

# Open Session Workflow

When the user asks to initialize or open the session, run this sequence:

## 1. Read the handoff

- Read `koder/STATE.md` first
- Note the `Current snapshot`, open issues and plans, and `Next step`
- Open only the issue or plan files relevant to the current task

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
- Prefer updating existing issue or plan docs over creating new tracking files
- Do NOT create issue docs unless the user explicitly asks
