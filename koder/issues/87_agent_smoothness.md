---
status: done
priority: P1
created: 2026-10-22
updated: 2026-10-22
tags: agents, claude-code, pi, mcp, ux
issue_kind: epic
type: feature
related: 86
plan: 39
---

# Issue 87 — Harnex should be butter smooth for agents

Owner (2026-10-22): "only stop when harnex works butter smooth with agents;
feel free to change anything in harnex to achieve that, including breaking
changes; and feel free to release a local install as often as you want."

The bar, baseline evidence (0.21.0) and design are in
`koder/plans/39_agent_smoothness.md`. Measure with `evals/agents/run`.

## Resolution (2026-10-22)

The bar was met on 0.28.0: rounds C and D of `evals/agents/run` each scored
28/28 pass with no harnex-caused errors, doc lookups or leftovers, across
Claude Code and Pi, with and without MCP. Shipped in 0.22.0–0.28.0:

- lanes (`delegate`, `result`, `reply`, `land`, `discard`, `lanes`);
- `harnex mcp` and `harnex mcp install`;
- the MCP guard for workers;
- progress detail;
- hygiene (`info/exclude`, the hand-merge sweep, pruning).

Evidence: `koder/releases/0.22.0.md` … `0.28.0.md`; plan 39 has the
progress log and outcome.

