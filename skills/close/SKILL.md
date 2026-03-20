---
name: close
description: Close a work session in this repo — update koder/STATE.md with what changed and the next step, clean up accidental or temporary repo artifacts, and leave a clear handoff. Use when the user says "close session", "wrap up", "end session", "handoff", or invokes "/close".
---

# Close Session Workflow

When the user asks to wrap up or close the current session, run this sequence:

## 1. Review the session changes

- Check `git status --short` and `git diff --stat`
- Separate the work from this session from unrelated user changes
- Do not revert unrelated changes you did not make

## 2. Update `koder/STATE.md`

- Update the `Updated:` date
- Add or adjust concise lines in `Current snapshot` for completed work
- Update test count if it changed
- Update issue or plan statuses only when work was actually completed or a new blocker was clearly discovered
- Rewrite `Next step` so the next agent can resume without reconstructing context

## 3. Clean up repo artifacts

- Remove temporary files, scratch notes, or mistaken tracking docs created during the session
- Keep durable artifacts that are part of the intended result
- If cleanup would discard ambiguous work, ask the user instead of guessing

## 4. Verify the handoff

- Run the relevant tests or verification commands if code or docs changed
- Check the final `git status --short` output for any leftover surprises
- Give the user a concise summary of what changed and any remaining follow-up

## Notes

- Do NOT create or close issue docs unless the user explicitly asks
- Do NOT commit, build, install, or publish anything unless the user explicitly asks
- If `koder/STATE.md` is already accurate, keep the update minimal rather than churning it
