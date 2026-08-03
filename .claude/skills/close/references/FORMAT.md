# Close Output Format

Render this as plain text, not a fenced code block:

Session Closed: **<repository>**

━━━
Git           `clean` or `BLOCKED — <count> path(s)`
Commits       `<count>` this session
State         `state: close - <semantic result>` (`<commit>`)
Checks        `✔ <commands>` or `✘ <failure>`
Remote        `synced` or `<ahead/behind detail>` (reported, not implicitly pushed)

━━━
**Notes** (optional — only when something needs attention next time)
- <warning, unresolved review, or remote drift>

━━━
**This Session**
- <durable work completed>
- <validation or commit result>

**Next Session**
- <next task>
- <known risk or follow-up>

━━━
*<one-line summary of the session’s impact>*
*<parting note describing what is now possible or what remains blocked>*

## Rendering rules

- Use `━━━` as the separator; do not use `---`.
- Use inline code for commits, paths, commands, and issue numbers.
- Keep **This Session** and **Next Session** terse: one line per bullet, no sub-bullets.
- Omit **Notes** when the repository is clean, validation passed, and no follow-up warning exists.
- `Git clean` is a factual claim, not an aspiration. Any output from `git status --porcelain=v1 --untracked-files=all` means `BLOCKED`.
- If close is blocked, change the title to `Session Close Blocked: **<repository>**`, keep the same separators, list exact dirty paths in **Notes**, and make the parting note the required operator decision.
- Do not claim remote synchronization unless it was checked. Local cleanliness does not imply the remote is current.
