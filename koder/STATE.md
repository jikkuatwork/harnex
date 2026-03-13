# Harnex State Handoff

Updated: 2026-03-14T01:16:00+04:00

## Why this file exists

This repo recently fixed a relay-submission bug where Claude-to-Codex
`harnex send` messages could appear in the Codex input box without being
submitted automatically.

This file is the committed recovery note for that work and for the live
Codex-Claude discussion workflow now documented in `README.md`.

## Current repo state

- Relay send fixes and the discussion workflow docs were committed in:
  - `65b3e11` - `Improve relay sends and document live discussion workflow`
- `tmp/` is intended to stay local scratch space and is now ignored by Git.
- `koder/STATE.md` is tracked so the relay context survives session restarts.
- The intended operating mode is one live Codex session and one live Claude
  session under the same workflow label.

## What changed

- `lib/harnex.rb`
  - exports session context to child processes so wrapped sessions know who
    they are
  - auto-wraps cross-session sends with a relay header
  - supports multi-step injection and serializes stdin with automated writes
  - waits briefly for a sendable screen state before submitting
- `lib/harnex/adapters/base.rb`
  - adds adapter hooks for short send-time waiting
- `lib/harnex/adapters/codex.rb`
  - waits briefly for a real prompt before auto-submit
  - injects message text and submit bytes as separate steps
  - returns a clearer blocked-state message when Codex is busy
- `README.md`
  - documents automatic relay headers
  - documents a human-steerable live discussion workflow between Codex and
    Claude

## What was validated

- Ruby syntax checks passed for:
  - `lib/harnex.rb`
  - `lib/harnex/adapters/base.rb`
  - `lib/harnex/adapters/codex.rb`
- A disposable probe Codex session received relays from the live `hh` Claude
  session and replied correctly to:
  - a single-line prompt
  - a multiline prompt
- A direct live `hh` exchange between Codex and Claude succeeded after restart:
  - Claude relayed a message back into the live Codex session
  - Codex relayed an acknowledgement back to Claude
- The relay messages arrived as submitted prompts, not as unsent text left in
  the input box.

## Live discussion workflow

1. Start both sessions:

```bash
./bin/harnex run codex --label hh
./bin/harnex run claude --label hh
```

2. Seed a topic from your shell:

```bash
./bin/harnex send --label hh --cli codex --message "Topic: should Harnex ship screen_tail before SSE?"
```

3. Ask the other side to reply through Harnex:

```bash
./bin/harnex send --label hh --cli claude --message "Please reply back to Codex through harnex, then wait for follow-up."
```

4. Pause either pane at any time and steer it directly. If you want one side to
answer the other, ask it explicitly to run `harnex send` back across the shared
label.

## Likely next follow-up

Observability is still the weak point. `harnex send --status` exposes session
state, but it does not return a sanitized recent screen buffer. A small
read-only `screen_tail` or `/screen` endpoint is still the most useful next
step; SSE can layer on top later.
