# Harnex State

Updated: 2026-10-22 | 06:25 PM | IST

Thin session handoff. History: `CHANGELOG.md`; release evidence:
`koder/releases/`; implementation detail: linked issues/plans.

## Past

- **0.29.0, the agent release, is installed locally, with docs and a
  website.**
  - Docs: lanes, MCP, coding agents, upgrading.
  - The `gpt` agent ships in the gem.
  - https://harnex.zyt.app is a Holm app built from the docs by
    `site/build.rb` (app `holm_app_wQ4TB6JUhrTZ` on peer `zyt`).
  - Record: `koder/releases/0.29.0.md`.
- **#87 agent smoothness: done on 0.28.0 (installed locally).**
  - Two consecutive full eval rounds were clean on the same build: 28/28
    pass, no harnex-caused errors, no doc lookups, no leftovers. They
    covered Claude Code and Pi, each with and without MCP.
  - **Shipped in 0.22.0–0.28.0:**
    - lanes: `delegate [--worktree]`, `result`, `reply` (resumes the
      worker's Pi session), `land`, `discard`, `lanes`;
    - `harnex mcp` with `harnex mcp install`, registered for both clients;
    - workers never see harnex's own MCP tools;
    - the `gpt` agent relays over MCP.
  - Plan, bar and outcome: `koder/plans/39_agent_smoothness.md`.
    Evidence: `koder/releases/0.22.0.md`–`0.28.0.md`. Evals:
    `evals/agents/run` (results in `~/.cache/harnex-evals/`).
- #86 slices 1–2 are done. In slice 3, the lane shorthand is done;
  automatic capacity fallback is still open.

## Present

- **Owner direction:** exclusively Pi + GPT models. Releases are local only
  (suite green → version/CHANGELOG → `gem build` → `gem install --local` →
  smoke → `koder/releases/<v>.md` → STATE). Run `pi update` first.
- **MCP is registered:**
  - Claude Code at user scope, as the RubyGems wrapper `.../bin/harnex mcp`;
  - Pi in `~/.pi/agent/mcp.json` (exposure direct);
  - `harnex doctor` reports `integrations`.
- **Claude Code facts:**
  - agent types and MCP servers load at session start;
  - a main-session MCP call auto-backgrounds after 2 minutes and notifies
    (verified interactively);
  - headless `claude -p` stops background work after 10 idle minutes
    (`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` lifts it);
  - background results reach the parent XML-escaped.

## Future (suggested order)

0. **Owner's go-ahead pending:**
   - push `main` and tag `v0.29.0` to GitHub;
   - publish the kept `harnex-0.29.0.gem` (SHA-256 in the release record)
     with `bin/gem-push`. The 2FA secret is in the backup
     `~/scrap/harnex/.env`; copy it to the repo `.env`, which git ignores.
     The API key is in the environment;
   - set the app CSP `security.csp.frame_src https://feedback.zyt.app` so
     the feedback panel can open.
1. **#86 slice 3 rest:** automatic capacity retry/fallback for `delegate`
   and `run` (with #59/#82).
2. **Eval follow-ups:**
   - an Opus-supervisor round;
   - worktree bootstrap for repos that need `.env` or dependencies;
   - rerun `evals/agents/run` after any agent-facing change.
3. #41 Slice C (`docs/public_api.md`), #78 pane time markers, #17, #16
   (macOS), #59.
