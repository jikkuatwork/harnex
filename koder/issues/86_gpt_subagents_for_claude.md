---
status: open
priority: P1
created: 2026-10-22
updated: 2026-10-22
tags: claude-code, subagent, agent-type, mcp, pi, gpt
issue_kind: slice
type: feature
related: 59, 82, 85
---

# Issue 86 — GPT subagents in Claude Code

Owner question (2026-10-20): "how close are we to use harnex as gpt sub agents
in claude?" Answer: functionally close (0.19.0/0.20.0, #85); the missing piece
is the native invocation surface. Take up in a new session.

## Works today

- One blocking Bash call delegates and returns the GPT worker's reply:
  `harnex ask` (read-only) or `harnex run pi … --auto-stop --wait-done`
  (`turn_result.final_message`, `end_sha`, `turn_commits`, `model`).
- Parallel worktree lanes with `--owner-tag` isolation and one batch wait
  (`watch --owner --until-idle`); busy-lane follow-ups; nudged turns.
- Main session: `Monitor` on `harnex watch --owner` behaves like background
  subagent completion (events carry `final_message`).
- The `harnex` skill (`~/Projects/pi/.pi/skills/harnex`) routes Claude here.

## Gaps

1. **Invocation surface:** Claude reaches GPT through Bash plus a skill, not
   the Agent tool or a native tool.
2. **Long turns inside a subagent:** 10-minute Bash cap means looping on
   `resume` (the main session has `Monitor`).
3. **Resilience:** no retry/model fallback for `run` (only
   `ask --fallback-model`); rate limits surface after ~2 minutes of Pi retries;
   waits use `CLOCK_MONOTONIC` (host suspend unbounded).
4. **Lane setup is manual:** worktree creation, brief file, ~8 flags.
5. **Cost not in the result:** Pi per-turn cost is in dispatch rows only.

## Proposed slices (in order)

1. **`gpt` agent type:** `.claude/agents/gpt.md` kept in `~/Projects/pi` and
   linked into `~/.claude/agents/`; a thin Haiku bridge whose only job is to run
   harnex and return the worker's reply, so
   `Agent(subagent_type: "gpt", prompt: …)` gets Claude Code's own background
   runs and notifications. Stress-test with parallel subagents. (~half a day)
2. **`harnex mcp`:** stdio MCP server exposing `ask`, `delegate`, `send`,
   `status` as native tools; long lanes still report via `Monitor`. (~a day)
3. **Lane shorthand + retry/fallback:** `--worktree NAME` and
   `--retry-on capacity --fallback-model` (with #59/#82).
