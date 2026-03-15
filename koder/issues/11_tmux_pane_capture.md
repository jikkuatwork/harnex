---
id: 11
title: "Pane capture — clean screen snapshot for tmux sessions"
status: open
priority: P3
created: 2026-03-15
---

# Issue 11: Pane Capture for Tmux Sessions

## Problem

The transcript log (`~/.local/state/harnex/output/`) captures raw PTY output
including escape sequences, cursor movements, and partial redraws. It's useful
for full history but hard to parse for a quick "what does the screen look like
right now?" check.

For tmux sessions, `tmux capture-pane -t <window> -p` gives a clean,
human-readable snapshot of the current screen — exactly what a supervisor needs
to diagnose a stuck session.

## Observed During

Chain-implement v2: Codex session `cx-159` had state `unknown` despite being
at a prompt. Running `tmux capture-pane -t cx-159 -p` from the supervisor
instantly showed the `›` prompt marker, confirming the adapter detection was
wrong and the session was actually ready. This was far more useful than reading
the raw transcript.

## Proposal

### `harnex pane --id <session>`

For tmux-backed sessions, capture and print the current pane content:

```bash
harnex pane --id cx-159
```

Returns clean text (no escape sequences) showing the current visible screen.
Equivalent to `tmux capture-pane -t <window> -p`.

Options:
- `--lines N` — capture last N lines (default: full pane)
- `--json` — return as JSON with metadata (session ID, capture timestamp)

### Scope

- Only works for tmux sessions (`--tmux` mode). Returns an error for detached
  or foreground sessions.
- Read-only — no injection, no state mutation.
- Complements `harnex logs` (Issue 4 phase 2) which shows history. This shows
  the current screen.

### API endpoint (optional)

`GET /pane` on the session's HTTP server. Runs `tmux capture-pane` and returns
the text. Useful for automated supervisors that want to inspect visually
without shelling out.

## Relationship to Other Issues

- **Issue 4 (output streaming)**: `harnex logs` shows full transcript history.
  `harnex pane` shows current screen snapshot. Complementary.
- **Issue 8 (startup timeout)**: pane capture would have immediately shown the
  prompt was visible despite `unknown` state, aiding diagnosis.
- **Issue 9 (vim mode detection)**: pane capture would show the vim mode
  indicator, helping debug adapter state detection mismatches.
