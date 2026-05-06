---
status: backlog
---

# Issue 04: Output Streaming

**Status**: open (P3 — remaining work is low priority)
**Priority**: P3
**Created**: 2026-03-14
**Tags**: feature, architecture

## Current state

Output visibility is effectively solved for the primary use cases:

- Session-owned transcript file at
  `~/.local/state/harnex/output/<repo>--<id>.log` (phase 1)
- `harnex logs --follow` tails raw transcript output (phase 2)
- `harnex pane --follow` refreshes the clean rendered screen at an interval,
  covering the "what's happening now?" supervisor use case for tmux sessions

What remains (low priority):

- No read-only HTTP output endpoint for dashboards
- No retention/rotation policy for long-lived transcripts
- `harnex pane` only works for tmux sessions; detached headless sessions
  can only be monitored via `harnex logs`

## Planned phases

### Phase 1 — Session-owned transcript file

Done.

### Phase 2 — `harnex logs`

Done.

### Phase 3 — Read-only output API (deferred)

Add a cursor or byte-offset based HTTP endpoint for dashboards and other local
consumers. Deferred — `harnex pane --follow` covers the primary supervisor use
case. Revisit only if a browser/dashboard or detached-session monitoring
becomes a real need.
