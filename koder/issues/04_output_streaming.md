# Issue 04: Output Streaming

**Status**: open
**Priority**: P2
**Created**: 2026-03-14
**Tags**: feature, architecture

## Problem

Harnex captures PTY output into a 64KB ring buffer for internal state
detection, but there's no way for external consumers to read that output.

A supervisor orchestrating workers is blind to what they're doing. It can only:
- Check state (`prompt` / `busy` / `blocked`)
- Wait for exit
- Read files the worker happened to write

It can't see the worker's reasoning, progress, errors, or partial output.

## Use Cases

### 1. Supervisor visibility

A chain-implement supervisor spawns an implement worker. While the worker runs
(5-10 minutes), the supervisor has zero visibility. With output streaming, it
could:
- Show a live progress summary
- Detect early failures without waiting for exit
- Make smarter decisions about when to intervene

### 2. Web dashboard

Stream session output to a webapp for monitoring multi-agent workflows. A
simple SSE or WebSocket endpoint on the existing HTTP server would allow a
browser to show live terminal output for all active sessions.

### 3. Logging and audit

Capture full session transcripts for post-mortem analysis. Today the ring
buffer overwrites — long sessions lose early output.

## Possible Approaches

### A. SSE endpoint on existing HTTP server

```
GET /output/stream
Authorization: Bearer <token>

data: {"ts": "...", "chunk": "raw pty bytes (base64 or utf8)"}
data: {"ts": "...", "chunk": "..."}
```

Pros: Uses existing HTTP server, no new dependencies.
Cons: SSE is unidirectional (fine for this use case).

### B. Log file + tail

Write all PTY output to a file (`~/.local/state/harnex/logs/<repo>--<id>.log`).
Consumers tail it. `harnex logs --id worker` as a convenience command.

Pros: Simple, works with existing Unix tools.
Cons: Disk usage, no structured framing.

### C. Ring buffer API endpoint

```
GET /output?since=<cursor>&limit=100
```

Return chunks from the ring buffer with cursors for pagination.

Pros: No disk overhead, random access.
Cons: Limited history (64KB), cursor management complexity.

## Recommendation

Start with **B** (log file + `harnex logs`). It's the simplest, most Unix-y
approach. The log file is useful even without streaming (post-mortem). Add **A**
(SSE) later when real-time dashboard needs emerge.

## Scope Note

This is a long-term capability, not urgent. Filing to capture the idea while
the orchestration model is being designed. The initial chain-implement rewrite
can work without this — the supervisor reads working tree state and result
files. But as workflows get more sophisticated, output visibility becomes
essential.
