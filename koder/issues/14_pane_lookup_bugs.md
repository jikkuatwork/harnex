---
id: 14
title: "Pane lookup fails for worktree sessions and custom tmux window names"
status: fixed
priority: P2
created: 2026-03-21
---

# Issue 14: Pane Lookup Fails for Worktree Sessions and Custom Tmux Window Names

## Problem

`harnex pane --id <session>` fails in two independent ways when the session was
launched in a git worktree with a custom `--tmux NAME`.

### Bug 1: Repo root mismatch for worktree sessions

`resolve_session` (pane.rb:87-98) calls `Harnex.resolve_repo_root(Dir.pwd)` to
find the registry entry. When a session is launched with
`--cd /path/to/worktree`, the registry stores the worktree path as `repo_root`.
But when `harnex pane` is run from the main repo (e.g. master), the resolved
repo root is the main repo path — not the worktree path. Lookup fails:

```
$ harnex pane --id cx-rev-181 --lines 30
harnex pane: no active session found with id "cx-rev-181" for /home/.../holm/master
```

Even passing `--repo <worktree-path>` doesn't reliably fix it because git
worktrees may resolve repo roots differently.

**Registry evidence:**
```json
{
  "repo_root": "/home/.../holm/plan-181-member-peer-persona",
  "cwd": "/home/.../holm/master"
}
```

### Bug 2: Tmux window name != session ID

Line 57 of pane.rb uses `session.fetch("id")` as the tmux window target:

```ruby
window = session.fetch("id")
return 1 unless tmux_window_exists?(window)
```

But when a session is launched with `--tmux cx-181 --id cx-rev-181`, the actual
tmux window name is `cx-181`, not `cx-rev-181`. The registry doesn't store the
tmux window name, so `tmux has-session -t cx-rev-181` fails:

```
harnex pane: session "cx-rev-181" is not tmux-backed or the tmux window no longer exists
```

This is confirmed in run.rb:109:
```ruby
window_name = @options[:tmux_name] || @options[:id]
```

The window name falls back to ID only when `--tmux` is bare (no NAME argument).
When a custom name is given, the registry has no record of it.

## Reproduction

```bash
# From master worktree
harnex run codex --id cx-rev-181 --tmux cx-181 \
  --context "review plan 181" \
  -- --cd /path/to/plan-181-worktree

# Both fail:
harnex pane --id cx-rev-181 --lines 30          # Bug 1: wrong repo root
harnex pane --id cx-rev-181 --lines 30 \
  --repo /path/to/plan-181-worktree              # Bug 2: wrong tmux window name

# Workaround: direct tmux
tmux capture-pane -t cx-181 -p -S -30           # works
```

## Resolution

Fixed on 2026-03-21.

Shipped changes:

1. **Real tmux target lookup** — `harnex pane` no longer assumes the harnex
   session ID is a valid tmux target. It now prefers a persisted
   `tmux_target` and otherwise discovers the live pane by matching
   `session["pid"]` against `tmux list-panes`.

2. **Registry persistence for tmux metadata** — tmux-backed launches now
   annotate the registry with:
   - `tmux_target`
   - `tmux_session`
   - `tmux_window`

   Session registry rewrites preserve these `tmux_*` keys so the metadata
   survives later sends and status updates.

3. **Cross-repo fallback for `pane`** — if lookup fails in the current repo
   scope and `--repo` was not explicitly provided, `harnex pane` falls back
   to a unique global session match by ID. If multiple matches exist, it now
   fails with a clear disambiguation error instead of silently picking one.

4. **Regression coverage** — tests now cover:
   - custom tmux targets
   - cross-repo/worktree lookup fallback
   - pane-target discovery from the session PID
   - preservation of tmux metadata in the registry

## Relationship to Other Issues

- **Issue 11 (pane capture)**: Issue 11 designed the feature. This issue tracks
  bugs in the shipped implementation.
- **Issue 3 (API design audit)**: Registry schema missing `tmux_window` field
  is a design gap that an audit would have caught.
