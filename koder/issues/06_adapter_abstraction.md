---
title: Full adapter abstraction
status: open
priority: P2
created: 2026-03-15
---

# Issue 06: Full Adapter Abstraction

**Status**: open
**Priority**: P2
**Created**: 2026-03-15

## Problem

The adapter contract covers the common cases (prompt detection, text
injection, exit sequence) but assumes a PTY-based TUI interaction model.
Future adapters for non-standard CLIs may need:

- **Custom exit strategies**: Ctrl+C, SIGTERM, multi-step quit dialogs,
  HTTP API calls to a local server
- **Richer injection steps**: wait-for-pattern-then-type, conditional
  branching, backspace-before-type
- **Non-text input**: file-based communication, API-based input
- **Lifecycle hooks**: on_start (post-spawn setup), on_output (custom
  output processing), on_exit (cleanup)
- **Custom readiness detection**: poll an HTTP endpoint, check a file,
  wait for a specific log line — instead of screen scraping

## Current state after plan 02

Plan 02 (Phase 0b) moves `inject_exit` and `wait_for_sendable` behind
the adapter boundary, which is sufficient for any adapter that
communicates via PTY text. The contract is documented in `base.rb`.

## What this issue would add

A richer adapter interface for non-PTY or hybrid CLIs:

```ruby
# Full lifecycle hooks
def on_spawn(session)    end  # called after PTY.spawn
def on_output(chunk)     end  # called on each PTY output chunk
def on_exit(exit_code)   end  # called before cleanup

# Richer injection
def inject_steps(context)
  # Returns an array of steps, each can be:
  #   { type: :write, text: "..." }
  #   { type: :wait_for, pattern: /regex/, timeout: 5 }
  #   { type: :key, code: :ctrl_c }
  #   { type: :sleep, seconds: 0.5 }
end
```

## When to do this

When a third adapter is being built and hits the wall with the current
contract. Don't abstract ahead of need — let real use cases drive the
design.

## Related

- Plan 02, Phase 0b (adapter contract cleanup)
- Issue #04 (output streaming — may interact with on_output hook)
