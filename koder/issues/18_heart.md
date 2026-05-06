---
status: resolved
priority: P2
created: 2026-04-18
updated: 2026-04-18
tags: recipe,pattern
---

# Issue 018: Buddy Pattern — Accountability Partner for Long-Running Sessions

## The Problem

AI agents are stateless and reactive. When a multi-step pipeline runs overnight,
nothing recovers from simple failures. On 2026-04-18, an overnight automation died
silently because one bad exit code killed everything — after training had already
succeeded. The pipeline hadn't lost information; it had lost **continuous presence**.

## Design Principle

**Harnex wraps the things you spawn, never yourself.** The human's session
stays raw — you just run `claude` normally. Harnex is invisible infrastructure
for workers.

## The Insight

Harnex already has every primitive required: `harnex status` (detect stalls),
`harnex pane` (read context), `harnex send` (nudge). The missing piece is a
**usage pattern**, not code — plus one env var to close the return channel.

## The Pattern: Spawn a Buddy

For long-running work, the invoking agent spawns a second harnex session — a
"buddy" — whose only job is to periodically check on the worker and nudge it
if it stalls.

The buddy is itself an LLM agent, so it has intelligence for free. It can read
the worker's pane, understand context, and compose a meaningful nudge. No
special monitoring code, no LLM provider integration in harnex, no config files.

```bash
# The invoking agent spawns a worker...
harnex run codex --id worker-42 --tmux

# ...and a buddy to watch it
harnex run claude --id buddy-42 --tmux
harnex send buddy-42 "You are an accountability partner for session worker-42.
Every 5 minutes, run 'harnex pane --id worker-42' and 'harnex status --json'.
If the worker appears stuck at a prompt for more than 10 minutes, nudge it
with 'harnex send worker-42 <your nudge message>'. Keep watching until it
finishes or is stopped."
```

The buddy uses existing harnex primitives — no new API surface needed.

## Return Channel: `$HARNEX_SPAWNER_PANE`

The invoker (human's Claude session) is not harnex-managed — it has no registry
entry, no API server. So `harnex send` can't reach it. But it IS in a tmux pane.

At spawn time, `harnex run` captures the invoker's `$TMUX_PANE` and passes it
to the child session as `$HARNEX_SPAWNER_PANE`. This gives every spawned agent
a return channel to its invoker without requiring the invoker to be harnex-managed:

```bash
# The buddy reads the invoker's screen
tmux capture-pane -t "$HARNEX_SPAWNER_PANE" -p

# The buddy types into the invoker
tmux send-keys -t "$HARNEX_SPAWNER_PANE" "hey, you seem stuck!" Enter
```

The buddy is an LLM — it can `capture-pane` first to check whether the invoker
looks stalled before typing. The intelligence is in the buddy, not in harnex.

**Implementation:** one line in `Session#child_env`:
```ruby
env["HARNEX_SPAWNER_PANE"] = ENV["TMUX_PANE"] if ENV["TMUX_PANE"]
```

## What This Is

- A **recipe** (like fire-and-watch and chain-implement), not a feature
- Uses existing primitives: `status`, `pane`, `send`, `tmux send-keys`
- The buddy is a regular harnex session — can be stopped, inspected, logged
- The invoking agent controls the polling interval, stall threshold, and nudge
  style through the prompt it sends the buddy
- One small code change (`$HARNEX_SPAWNER_PANE`) to close the return channel

## What This Is NOT

- Not a built-in stall timer or heartbeat system
- Not an LLM integration inside harnex
- Not a new command (`harnex heart` is not needed)
- Not a config file or provider abstraction
- Not a reason for the human to run `harnex run` on their own session

## Deliverables

- [ ] Add `$HARNEX_SPAWNER_PANE` to `Session#child_env` (one line)
- [ ] Recipe doc: `recipes/03_buddy.md`
- [ ] Mention in CLAUDE.md / skill docs: "for long-running work, spawn a buddy"
- [ ] Optional: mature into a skill (`/buddy`) if the pattern proves valuable

## Origin

Born from MoMa Issue 006 — an overnight training pipeline that died silently.
Originally scoped as an LLM-powered monitor (`harnex heart`), simplified through
design review to a pure usage pattern over existing harnex primitives.
