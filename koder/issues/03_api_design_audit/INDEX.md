# Issue 03: API & Command Design Audit

**Status**: open
**Priority**: P1
**Created**: 2026-03-14
**Tags**: design, PoLS

## Summary

The CLI grew organically and has accumulated PoLS (Principle of Least Surprise)
violations. This issue tracks a design pass to make the surface predictable
before more workflows depend on it.

## Critical — Silent Data Loss or Broken Semantics

### 3a. `--status` silently discards text

`harnex send --status --message "implement X"` queries `/status` and throws
away the message. No error, no warning.

**Fix**: Error if `--status` is combined with `--message`, positional text, or
stdin. They're mutually exclusive modes.

### 3b. `--enter` + `--no-submit` override each other

`--enter` sets `submit = true`, then `--no-submit` sets `submit = false`. The
last flag wins silently depending on parse order.

**Fix**: Validate mutual exclusivity. `--enter`, `--no-submit`, and normal send
are three distinct modes — pick one.

### 3c. `--force` doesn't actually force immediate delivery

`--force` bypasses the adapter state check but the message still gets queued if
the inbox has pending items. Users expect "force" = "deliver now."

**Fix**: Either make `--force` skip the queue (true force), or rename to
`--ignore-state` to match actual semantics.

## High — Confusing Behavior

### 3d. Exit status files collide across repos

Keyed by `<id>.json` only. Two repos with `--id worker` overwrite each other's
exit files. Registry files use `<repo_hash>--<id>.json` — exit files should too.

**Fix**: Align exit file naming with registry convention.

### 3e. Session lookup falls back silently

When `--id` is omitted, `send` falls back to `HARNEX_SESSION_ID` → env →
default CLI name. If no session matches, the error doesn't say what ID was
tried.

**Fix**: Include the resolved ID in error messages. Consider requiring `--id`
explicitly (no magic fallback).

### 3f. `--enter` has hidden adapter precondition

Claude adapter only allows `--enter` at the workspace trust prompt. Codex
allows it anywhere. The CLI help doesn't mention this. Error message doesn't
explain the constraint.

**Fix**: Adapter-specific constraints should surface in the error message:
"Claude only accepts --enter at the workspace trust prompt."

### 3g. `--relay` only applies to `send`, not `run --context`

`--context` injects text at session start but doesn't add relay headers. If a
supervisor spawns a worker with `--context`, the worker can't tell who sent it.

**Fix**: Apply relay headers to `--context` when the spawner is inside a harnex
session (same env var check as `send`).

## Medium — Inconsistencies

### 3h. `--label` is a silent deprecated alias for `--id`

No deprecation warning. Users reading old examples use `--label`, new docs say
`--id`. Silent alias hides the migration.

**Fix**: Emit a stderr warning: `--label is deprecated, use --id`. Remove in
next major version.

### 3i. HTTP API has implicit mode switching

The `/send` endpoint switches between `:adapter` and `:legacy` mode based on
which JSON fields are present. No explicit mode field.

**Fix**: Either drop legacy mode or add an explicit `"mode": "adapter"` field.

### 3j. `--detach` + `--tmux` redundancy

`--tmux` implies `--detach`. Passing both is redundant but not warned about.

**Fix**: Minor — just document it. Or warn on stderr.

### 3k. Default CLI is `codex`, undocumented

`harnex` with no args runs codex. `harnex run` with no CLI name runs codex.
Not mentioned in `--help` or README.

**Fix**: Show default in help text: `harnex run [CLI] (default: codex)`

### 3l. Help text doesn't show defaults

`--host`, `--port`, `--timeout` all have defaults but help text doesn't
display them.

**Fix**: Standard practice — add `(default: 127.0.0.1)` etc.

### 3m. Error messages are adapter-specific, inconsistent tone

Codex says "wait and retry or use...". Claude says "waiting on workspace trust
prompt...". Different detail level, different remediation advice format.

**Fix**: Standardize error template: `"<CLI> is <state>. <remedy>."`

### 3n. `--watch` silently creates parent directory

Typo in path creates a new directory instead of erroring.

**Fix**: Only create if parent already exists. Or warn on creation.

## Low — Code-Level Cleanup

- `submit_bytes` naming is misleading (it's always `\r`)
- `infer_repo_path` evaluated at parse time, not spawn time
- Codex adapter `build_send_payload` returns `steps` shape, differs from base
- `allow_control_action?` / `wait_for_sendable_state?` have unclear contracts
- Port hash can collide across repos (forward-walk recovery exists but undocumented)
- Registry deletion → exit file write has a narrow race window
