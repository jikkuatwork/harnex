---
status: open
priority: P3
created: 2026-10-20
updated: 2026-10-20
tags: watch, owner-stream, claude-code, subagent
issue_kind: slice
type: feature
related: 59, 77
---

# Issue 84 — `harnex watch --owner --once`

A Claude Code subagent cannot be woken by a background notification once it ends its turn, so
it must block in a foreground Bash call (10-minute cap per call). `harnex watch --owner` (#77)
has no exit-on-first-event mode, so each blocking call runs to its max-wait and reports an event
up to about 9 minutes late. Per-lane `harnex wait` returns at once but covers one lane per call,
and four parallel lanes need a hand-written multi-wait script.

Want: `harnex watch --owner --once [--timeout DUR]`. It prints the first undelivered owner event
as JSON, advances the cursor and exits 0, or exits 124 on timeout. Then one blocking call covers
every lane the owner launched. Note that a subagent inherits its parent's
`CLAUDE_CODE_SESSION_ID`, so parent and subagent would share one cursor and take each other's
events (`lib/harnex/owner_stream.rb` cursor per owner dir). Allow an explicit `--owner <id>` or
a cursor name. The full answer is still the #59 conveyor runner; this is the small step.
