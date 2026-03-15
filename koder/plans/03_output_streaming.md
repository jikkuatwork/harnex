# Output Streaming Plan

Date: 2026-03-15

## Goal

Make session output readable for supervisors and local tooling across all run
modes without changing harnex's local-only control model.

## Constraints

- Keep the existing 64KB in-memory ring buffer for prompt/state detection
- Stay stdlib-only
- Use repo-scoped paths so repeated IDs do not collide across repositories
- Avoid turning transcript I/O failures into PTY/session failures
- Treat detached wrapper logs as incidental; the session transcript should be
  the durable interface

## Current baseline

- `Session#record_output` is the one place where PTY output already flows
- Phase 1 is now implemented:
  - repo-keyed transcript path helper in `core.rb`
  - PTY output appended to a session-owned transcript file
  - `output_log_path` exposed through `status` payloads and detached `run`
    responses
- Phase 2 is now implemented:
  - `harnex logs` reads the transcript for live sessions via the registry
  - exited sessions fall back to the repo-keyed transcript path directly
  - `--lines N` snapshots the last N lines (default 200)
  - `--follow` polls the file for growth until the session exits
- There is still no HTTP output API for local tooling

## Phase 1: Session-owned transcript file

Status: done

Shipped work:

1. Add `Harnex.output_log_path(repo_root, id)`
2. Open/create the transcript in append mode at session start
3. Append PTY output from `Session#record_output`
4. Keep transcript failures best-effort so the session keeps running
5. Expose `output_log_path` via session status and detached `run`
6. Add regression tests for the helper and transcript writes

## Phase 2: `harnex logs`

Status: done

Add a read-focused CLI on top of the transcript file.

### Proposed surface

```text
harnex logs --id ID [options]

--id ID         Session ID to inspect (required)
--repo PATH     Resolve using PATH's repo root (default: current repo)
--cli CLI       Optional session filter
--follow        Keep streaming appended output until interrupted or session exit
--lines N       Print only the last N lines before following (default: 200)
-h, --help
```

### Implementation notes

- Create `lib/harnex/commands/logs.rb`
- Resolve the active session from the registry when present
- Fall back to the repo-keyed transcript path when the session already exited
- For `--follow`, poll the file for growth instead of shelling out to `tail -f`
- Do not require the HTTP API for the CLI path; the transcript file is enough
- Add CLI/help wiring in `lib/harnex.rb` and `lib/harnex/cli.rb`

### Tests

- help text and CLI dispatch
- missing session / missing transcript errors
- snapshot output from an existing transcript
- follow mode printing new bytes appended after startup
- exited-session lookup using the repo-scoped transcript path

## Phase 3: Read-only output API

Status: later

After `harnex logs` settles, add an authenticated HTTP tail endpoint.

### Proposed shape

```text
GET /output?offset=<bytes>
Authorization: Bearer <token>
```

Response should include:

- current chunk bytes
- next offset
- whether EOF was reached
- whether the session is still running

### Why not SSE first

SSE is only needed for push delivery to browsers. A byte-offset tail endpoint is
simpler, easier to test, and good enough for both CLI polling and local tools.

## Open questions

- Whether transcripts should be rotated or left for manual cleanup
- Whether `run --detach` should eventually stop emitting the incidental wrapper
  log path once `harnex logs` is in place
- Whether the HTTP endpoint should emit UTF-8 text only or support raw bytes via
  base64 framing

## Verification checklist

```bash
ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'
ruby -Ilib bin/harnex help
ruby -Ilib bin/harnex logs --help
```

If a live session is available:

```bash
harnex status --json
harnex logs --id <live-id> --lines 50
harnex logs --id <live-id> --follow
```
