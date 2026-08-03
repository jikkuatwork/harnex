# Open Output Format

Render this as plain text, not a fenced code block:

Session Opened: **<repository>**

━━━
Branch        `<branch>`
Git           `clean` or `dirty — <count> path(s)`
Sync          `✔` or `✘ <ahead/behind detail>`
Last Session  `<timestamp>` (`<time ago>`)
Commits       `<total>` total · `<since handoff>` since handoff
State         `<READY | IN_PROGRESS | REVIEW_READY | BLOCKED | DONE | unknown>`
Window        `<active authorization window>`
Mode          `<blind orchestrator | direct | unspecified>`
Stop Gate     `<hard boundary>`

━━━
**Notes** (optional — only when something needs attention)
- <short warning, dirty path summary, or missing handoff>

━━━
**Past**
- <durable completed work from STATE.md>

**Present**
- <current state and important caveat>

**Future**
- <next likely task or risk>

━━━
*<one-line judgment about the project's current position>*
*<suggested next action, phrased so typing “yes” is enough>*

## Rendering rules

- Use `━━━` as the separator; do not use `---`.
- Keep the stat block compact and aligned. Omit fields whose facts are unavailable rather than inventing values.
- Use inline code for branches, commits, issue numbers, and file paths.
- Omit **Notes** when the tree is clean, upstream is synchronized, and the handoff has no warning.
- **Past**, **Present**, and **Future** come from `koder/STATE.md`; they are not substitutes for live Git facts.
- **Window**, **Mode**, and **Stop Gate** come from `koder/STATE.md` plus `koder/docs/EXECUTION.md`; omit them when no bounded execution contract exists. When Mode is `blind orchestrator`, the suggestion must say the primary routes isolated workers and does not read implementation detail.
- Derive commit and elapsed-time counts only when the handoff provides enough information; otherwise omit them.
- The final judgment is an interpretation, not another status list. Prefer the active bounded window from **Future**, include its stop condition, and phrase the suggestion so “yes” is enough.
