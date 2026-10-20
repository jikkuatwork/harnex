---
status: resolved
priority: P1
created: 2026-10-20
updated: 2026-10-20
tags: claude-code, subagent, ask, owner-stream, results, orchestration
issue_kind: slice
type: feature
related: 79, 80, 81, 83, 84
---

# Issue 85 — Pi (GPT) workers as native tools for Claude Code

Owner request (2026-10-20): "stress test so that harnex works flawlessly with
claude subagents … it should feel like harnex is natively part of claude, so
that gpt models become natural tools for claude."

Live stress runs with Claude Code subagents on 0.18.0 (dogfood, S1 multi-lane
failure paths, S2/S3 two subagents sharing one owner) found:

- **No answer channel.** Nothing in harnex output carried the worker's reply;
  a subagent had to scrape `harnex logs` by eye (S3, "the most important
  finding").
- **Lost turns (bug).** The owner record kept only the latest turn; a turn
  replaced by the next before a poll was never delivered (S1, S2).
- **No lane scope.** Subagents inherit the parent's `CLAUDE_CODE_SESSION_ID`
  (only `CLAUDE_CODE_CHILD_SESSION=1` marks them), so each saw every other
  subagent's lanes and a fresh cursor replayed the owner's whole history, out
  of order.
- **Too many steps.** Launch-then-wait, `--once` one event per call, no
  one-call question to another model.
- Smaller: `send` to an exited lane spent its whole timeout; `wait` reported
  a stopped, exited session as running; stall lines lacked turn/elapsed and
  could not tell a long `sleep` from a hung model; `send --wait-done` timeout
  output read as "delivered".

## Decisions (implementer, on the owner's instruction to think of smarter options)

- `harnex ask` for read-only one-call questions; `run --wait-done` for one-call
  delegation; `final_message` (+ path, `end_sha`, `commits`) on every turn
  result.
- Owner records keep a bounded per-turn `results` history; the stream
  delivers every turn once, in settle order.
- `--owner-tag TAG` (sub-owner `<session>/<TAG>`) on `run` and
  `watch --owner`; `--match GLOB` as the shared-owner alternative.
- `--once` prints every ready event.
- A Claude-facing guide (`harnex agents-guide claude`); a replacement for the
  stale user-level `~/.claude/skills/dispatch` skill is drafted but needs the
  owner's approval to install.

## Resolution

Shipped in 0.19.0 (local install). A second Claude-subagent round on the
checkout CLI (R1 `ask` second opinions, R2 three parallel tagged lanes merged
by the subagent, R3 one-call delegation with a 45 KB brief and a forced
timeout) succeeded with only the guide as instructions; its findings (heading
marks in `--context-section`, compound durations, asks dirtying the repo, a
follow-up counting race, no "wait for all lanes", per-turn commits, model in
results, guide gaps) were fixed before release. The stale Codex-era
`dispatch`/`chain-implement` Claude skills were replaced by the `harnex` skill
in `~/Projects/pi/.pi/skills/harnex` (linked for Claude and Pi).
