---
status: resolved
---

# Issue 03: API & Command Design Audit

**Status**: fixed
**Priority**: P1
**Created**: 2026-03-14
**Tags**: design, PoLS

## Summary

This audit is complete. The command/API redesign tracked in
`koder/plans/02_command_redesign.md` shipped on 2026-03-15, and the old
surface is no longer the reference point.

## Implemented outcomes

- Bare `harnex` shows help instead of spawning a default CLI
- `harnex run <cli>` requires an explicit CLI name and falls back to the
  generic adapter for unknown CLIs
- binaries are validated before `PTY.spawn`
- session IDs default to random two-word names instead of implicit CLI names
- `--description` is stored in the registry and exposed through `status`
- `harnex send` now requires `--id`, uses `--submit-only`, `--no-wait`,
  `--verbose`, and supports `--token` for direct `--port` mode
- `harnex wait --until prompt` is part of the normal lifecycle
- the old `exit` command/API was renamed to `stop` / `/stop`
- `harnex status` supports `--id` and `--json`
- session registry and exit-status files use repo-scoped slugs

## Tracker note

This issue was a design audit, not a permanent bucket for every follow-on
cleanup idea. New work should be tracked under focused issues instead:

- Issue 04 for output visibility and streaming
- Issue 06 for deeper adapter abstraction work
