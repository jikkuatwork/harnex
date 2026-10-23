# Harnex State

Updated: 2026-10-23 | 05:22 PM | IST

Thin session handoff. History: `CHANGELOG.md`; release evidence:
`koder/releases/`; implementation detail: linked issues/plans.

## Past

- **0.29.1 is installed locally (not published):** it fixes #88, where a repo
  phase allowlist with `"policy": "reject"` refused every lane. Lanes now
  run under the harnex-owned phases `delegate`/`ask` and accept `--phase
  NAME`. A launch refused before it starts leaves no lane record. Record:
  `koder/releases/0.29.1.md`.
- **0.29.0, the agent release, is published:** GitHub `main` with tag
  `v0.29.0`, and RubyGems (the first public release since 0.12.0). It comes
  with docs and a website.
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

- **Public vs local:** RubyGems, GitHub `main`/`v0.29.0` and the site are
  on 0.29.0; 0.29.1 exists only as local commits and the local install.
  Publishing it needs the owner's OK. After publishing, rebuild and redeploy
  the site, because `docs/lanes.md` and `docs/configuration.md` gained
  `--phase`.
- **Owner direction:** exclusively Pi + GPT models. Releases are local only
  (suite green → version/CHANGELOG → `gem build` → `gem install --local` →
  smoke → `koder/releases/<v>.md` → STATE) unless the owner approves
  publishing; 0.29.0 was approved and published. Run `pi update` first.
- **Site:** after a docs change, run `ruby site/build.rb`, then
  `holm @zyt app deploy site/app --spec-v1 --host harnex.zyt.app --force`.
  - Feedback project `6jyd3ya4`: the form's logo is `site/app/web/icon-512.png`
    (uploaded 2026-10-23; fallback icon `terminal`). Re-upload it if the
    symbol changes.
  - The launcher button still shows the feedback app's bubble mark. Swapping
    it means patching `site/src/assets/feedback.js`; that was offered, not done.
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

0. **If the owner approves, publish 0.29.1:** `bin/gem-push`, tag, push, and
   redeploy the site. Holm can then go back to `"policy": "reject"` (its
   `warn` workaround is commit `7ed759c14`).
1. **#86 slice 3 rest:** automatic capacity retry/fallback for `delegate`
   and `run` (with #59/#82).
2. **Eval follow-ups:**
   - an Opus-supervisor round;
   - worktree bootstrap for repos that need `.env` or dependencies;
   - rerun `evals/agents/run` after any agent-facing change.
3. **Site follow-ups:**
   - check it in Safari and Firefox, and as an installed app on a phone;
   - optionally a custom social card with the wordmark.
4. #41 Slice C (`docs/public_api.md`), #78 pane time markers, #17, #16
   (macOS), #59.
