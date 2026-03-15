# Issue 04: Output Streaming

**Status**: open
**Priority**: P2
**Created**: 2026-03-14
**Tags**: feature, architecture

## Current state

Harnex now has the first piece of output visibility, but not the full feature:

- `Session#record_output` still keeps the 64KB in-memory ring buffer used for
  state detection
- each session now also writes a repo-keyed transcript file at
  `~/.local/state/harnex/output/<repo>--<id>.log`
- transcript files now append across repeated same-ID launches instead of
  truncating prior output
- the transcript path is exposed as `output_log_path` in session status payloads
  and detached `run` responses

What is still missing:

- no `harnex logs` command to read or follow that transcript
- no read-only HTTP output endpoint for dashboards
- no retention/rotation policy for long-lived transcripts
- detached headless mode still has an incidental wrapper log at
  `~/.local/state/harnex/logs/<id>.log`; that file is not repo-keyed and should
  not be treated as the long-term output interface

## Why the issue stays open

Supervisors still cannot ask harnex itself for live progress. They can discover
the transcript path, but they must reach for external tools to read or tail it.

That leaves three important gaps:

1. No built-in operator UX
2. No stable API for web dashboards
3. No transcript lifecycle policy

## Recommended direction

Keep the file-first approach.

1. Make the session-owned transcript file the source of truth
2. Add a `harnex logs` command on top of it
3. Add a read-only tail API after the CLI semantics settle
4. Revisit SSE only if a browser/dashboard really needs push delivery

## Planned phases

### Phase 1 — Session-owned transcript file

Done.

### Phase 2 — `harnex logs`

Add a CLI command that can print the current transcript and optionally follow
new bytes while the session is still running.

### Phase 3 — Read-only output API

Add a cursor or byte-offset based HTTP endpoint for dashboards and other local
consumers. Consider SSE only after that simpler tail API proves insufficient.
