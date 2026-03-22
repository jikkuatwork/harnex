---
id: 16
title: "Use platform-agnostic data directory instead of ~/.local/state/"
status: open
priority: P2
created: 2026-03-22
---

# Issue 16: Platform-Agnostic Data Directory

## Problem

Harnex hardcodes `~/.local/state/harnex/` as the state directory. This follows
the XDG Base Directory spec (`$XDG_STATE_HOME`), which is Linux-specific.
On macOS there is no standard `~/.local/state/` — it works but feels foreign.
On Windows (WSL aside) it's wrong entirely.

As harnex targets multi-platform use (file watching already has a macOS polling
fallback), the data directory should also be platform-aware.

## Current state

From `lib/harnex/core.rb`:

- `HARNEX_STATE_DIR` defaults to `~/.local/state/harnex`
- Overridable via `HARNEX_STATE_DIR` env var
- Subdirectories: `sessions/`, `exits/`, `output/`

## Proposal

Switch the default data directory to `~/.harnex/`. Rationale:

- **Simple**: works identically on Linux, macOS, and Windows
- **Discoverable**: visible in home directory, easy to find and clean up
- **Precedent**: many tools use `~/.toolname/` (e.g. `~/.docker/`, `~/.npm/`,
  `~/.cargo/`)
- **No XDG dependency**: avoids needing to implement full XDG resolution or
  platform-specific paths like `~/Library/Application Support/` on macOS

### Alternative: `~/.config/harnex/`

Also cross-platform and slightly more conventional for config-like data, but
harnex state is runtime data (session registries, transcripts), not
configuration. `~/.config/` implies user-edited config files.

### Migration

1. Change the default in `HARNEX_STATE_DIR` from `~/.local/state/harnex` to
   `~/.harnex`
2. On startup, if `~/.harnex` doesn't exist but `~/.local/state/harnex` does,
   print a one-time notice suggesting the user move or delete the old directory
3. `HARNEX_STATE_DIR` env var continues to override — no breakage for anyone
   who set it explicitly
4. No automatic migration of old data — session registries and exit records
   are ephemeral anyway

## Files likely touched

- `lib/harnex/core.rb` — `HARNEX_STATE_DIR` default
- `test/` — any tests that reference the default path
- `README.md` / `GUIDE.md` — doc references to `~/.local/state/harnex`
