# Harnex State

Updated: 2026-10-22 | 04:14 PM | IST

Thin session handoff. History: `CHANGELOG.md`; release evidence:
`koder/releases/`; implementation detail: linked issues/plans.

## Past

- **#87 agent smoothness, in progress** (owner mandate 2026-10-22: work
  autonomously until harnex is "butter smooth with agents"; breaking changes
  and local releases allowed). 0.22.0–0.24.0 are installed locally:
  - lanes: `delegate`, `result`, `reply`, `land`, `discard` and `lanes`;
  - `harnex mcp` with `harnex mcp install`, registered for Claude Code
    (user scope) and Pi;
  - the `gpt` agent relays over the MCP tools;
  - the eval harness `evals/agents/run` covers 7 scenarios × 4 routes.
  - Plan, bar and progress log: `koder/plans/39_agent_smoothness.md`;
    records: `koder/releases/0.22.0.md`, `0.23.0.md`.
- 0.21.0 (#86 slice 1, `gpt` agent, `ask --resume`) and 0.20.0 (Pi + GPT
  only) shipped the same day.

## Present

- **Owner direction:** exclusively Pi + GPT models. Releases are local only
  (suite green → version/CHANGELOG → `gem build` → `gem install --local` →
  smoke → `koder/releases/<v>.md` → STATE). Run `pi update` first.
- **Unreleased in the tree:**
  - workers launch without harnex's own MCP tools; a read-only ask runs with
    `--no-mcp`. Pi keeps MCP tools despite `--tools`, so a read-only ask
    worker delegated a writable lane through harnex MCP in an eval;
  - progress formatting and lane-name generation are tidied;
  - the evals lift Claude's print-mode background ceiling
    (`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`).
- **Claude Code facts that matter:**
  - agent types and MCP servers load at session start;
  - background results reach the parent XML-escaped;
  - `claude -p` stops background work 10 idle minutes after the main turn;
  - `CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS` (10m) may also apply to
    subagents.

## Future (suggested order)

1. Release 0.25.0 with the MCP guard. Then rerun the evals until two
   consecutive full runs meet the bar in plan 39.
2. #86 slice 3: `run` capacity retry/fallback (with #59/#82).
3. #41 Slice C (`docs/public_api.md`), #78 pane time markers, #17, #16, #59.
