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

## Progress

### 2026-10-22: slice 1 built, first parallel stress test passed

- **Agent:** `~/Projects/pi/.claude/agents/gpt.md` (`model: haiku`,
  `tools: Bash`), linked as `~/.claude/agents/gpt.md`. It splits optional
  header lines (`model:`, `effort:`, `mode: write`, `cwd:`, `fallback:`),
  writes the brief through a quoted heredoc, runs
  `harnex ask --file … --timeout 9m`, loops on 124, and returns stdout
  verbatim plus a `— gpt: <lane, time, model>` line.
- **Harnex:** `ask --resume ID --repo ROOT` (unreleased). A timed-out ask now
  names an ask-shaped resume that prints the answer text, so the relay never
  parses JSON. Live check: forced 124 at 15s, the lane finished and
  auto-stopped, and the resume printed the full answer (exit 0).
- **Stress test** (headless `claude -p`, four `gpt` subagents in one message):
  all four returned in about 110s, and the parent was notified as each one
  finished.
  - **A, read-only:** correct in 14s.
  - **B, `model: foundry-zyt/gpt-6-luna`, `effort: low`:** correct in 96s, on
    the requested model.
  - **C, shell metacharacters:** the brief reached the worker and the relay's
    reply came back byte for byte.
  - **D, `mode: write` in a scratch repo:** fixed the bug, verified it and
    committed (22s).
- **Caveats:**
  - Claude Code loads agent types at session start; a session opened before
    the link existed cannot launch `gpt`.
  - The parent session receives background results XML-escaped. In C, the
    parent printed `&amp;` and `&gt;` although the relay's text was exact.
  - Until a release with `ask --resume` is installed, the relay on PATH
    (0.20.0) cannot loop on asks longer than 9 minutes.

### 2026-10-22: 0.21.0 installed; slice 1 done

- `ask --resume` shipped in 0.21.0, installed locally.
- Stress test: 8 `gpt` subagents launched at once from an interactive
  session. It covered an 11-minute task (124, then resume, then answer),
  parallel worktree writers, three models, a 4.4 KB verbatim relay, a bad
  model (reported, not answered) and a rate limit recovered with
  `fallback:`.
- Record: `koder/releases/0.21.0.md`.
- **Next:** slice 2 (`harnex mcp`). Optional polish: report the whole ask's
  time after a resume.
