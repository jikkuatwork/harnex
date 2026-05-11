---
status: open
priority: P2
---

# Issue 41 — Extract `Harnex::Codex::AppServer` module from adapter

**Status**: open
**Priority**: P2
**Filed**: 2026-05-11
**Tier**: B (plan → impl in thin slices)
**Sister**: #40 / plan 30 — Slice B implements plan 30 Phase 2 inside
the new module. #27 introduced the existing JSON-RPC adapter.

## Problem

`lib/harnex/adapters/codex_appserver.rb` (564 lines) bundles four
concerns into one file:

1. Adapter surface — `Harnex::Adapters::CodexAppServer` (state
   reporting, send, exit, build_send_payload).
2. JSON-RPC client lifecycle — the inner `JsonRpcClient` class
   (~240 lines: spawn, stdio framing, request/response correlation,
   notification dispatch).
3. Approval auto-responses — server→client approval requests harnex
   answers on the worker's behalf so dispatched runs go autonomous.
4. Future homes for resilience — disconnect detection, auto-resume,
   and (per #40 / plan 30) deployment fallback.

Every codex/Azure wart so far has been absorbed by the adapter file.
Plan 30 Phase 2 will add three more methods (`stop_for_fallback`,
`spawn_with_fallback`, `switch_deployment`). #40's eventual
"auto-resumed disconnects" counter and any future hardening
(jitter, backoff, deployment health tracking) will keep growing it.

This bloats the adapter and leaks codex-specific lifecycle into the
adapter contract that opencode (and any future harness) will be
asked to mirror.

## Proposal

Extract the JSON-RPC client + resilience layer into its own module
**outside `Harnex::Adapters::`**. The adapter becomes a thin
wrapper that consumes it.

### Namespace (proposed)

```
Harnex::Codex::AppServer::Client       # JSON-RPC subprocess lifecycle
Harnex::Codex::AppServer::Resilience   # (future) disconnect, fallback
Harnex::Adapters::CodexAppServer       # adapter — consumes the above
```

- Distinguishes the JSON-RPC codex stack from PTY-based
  `Harnex::Adapters::Codex`.
- `Harnex::Codex::` namespace leaves room for shared codex bits later
  (e.g. CLI-flag parsing) without forcing them under `AppServer`.
- Sets up a parallel home (`Harnex::OpenCode::AppServer::*`,
  `Harnex::Aider::*`, …) for harnesses that land next.

Alternatives:
- `Harnex::CodexAppServer::Client` — collides with the adapter class
  name `Harnex::Adapters::CodexAppServer`; readable but smelly.
- `Harnex::CodexAppServerClient` — flat, ugly, awkward to grow.

### Why this matters

- harnex's public surface gets quieter — codex/Azure resilience
  hacks live behind a clear seam, not in the adapter file.
- Second harness (opencode) gets a clear template rather than
  inheriting the adapter-as-kitchen-sink pattern.
- Plan 30 Phase 2 lands in the new module from day one, not as
  another scratch layered onto `codex_appserver.rb`.

## Slicing (thin)

### Slice A — pure refactor (this issue, blocking)

- Move `JsonRpcClient` from
  `lib/harnex/adapters/codex_appserver.rb` to
  `lib/harnex/codex/app_server/client.rb`.
- Rename to `Harnex::Codex::AppServer::Client`.
- Adapter requires the new file and references the new constant;
  no behavior change.
- All existing tests stay green with no test edits other than
  references to the moved constant where the name leaks (ideally
  zero — the adapter is the only consumer).
- Commit: `refactor(codex): extract JsonRpcClient to Harnex::Codex::AppServer::Client (#41)`

### Slice B — plan 30 Phase 2 in the new module

Tracked separately (plan 30 Phase 2). Lands inside
`Harnex::Codex::AppServer`:

- `Client#stop_for_fallback`
- `Client.spawn_with_fallback`
- `Adapters::CodexAppServer#switch_deployment` (thin delegation)
- Tests under `test/harnex/codex/app_server/`.

Blocked by Slice A.

### Slice C — public API surface doc

- `docs/public_api.md`: enumerates stable CLI commands, the env
  vars consumers can rely on (`HARNEX_ID`, `HARNEX_SESSION_CLI`,
  `HARNEX_SPAWNER_PANE`, `HARNEX_AUTOSTOP_TEARDOWN_GRACE_SECONDS`,
  `HARNEX_EXIT_STATUS_GRACE_SECONDS`), DISPATCH schema fields, and
  exit codes. Everything else marked internal.
- Buys refactoring headroom for the future cross-harness resilience
  interface without a 1.0 commitment.

Independent of Slices A/B; can land first if useful.

## Not in scope

- A generic `Harnex::Resilience` cross-adapter interface. Wait
  until opencode lands and a second instance reveals the shared
  shape — designing from one example bakes in codex assumptions.
- Renaming `Harnex::Adapters::CodexAppServer` itself. Stays put;
  only `JsonRpcClient` moves.
- A 1.0 release. The public API surface doc is a stability marker,
  not a release commitment.

## Cross-references

- #40 / plan 30 — deployment fallback. Slice B *is* its Phase 2,
  implemented in the new namespace.
- `lib/harnex/adapters/codex_appserver.rb` — Slice A's source.
- `CLAUDE.md` "Adapter transports" — PTY and JSON-RPC are both
  first-class; this extraction is for the JSON-RPC side only.
