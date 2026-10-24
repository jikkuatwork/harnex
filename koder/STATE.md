# Harnex State

Updated: 2026-10-25 | 02:20 AM | IST

Thin session handoff. History: `CHANGELOG.md`; release evidence:
`koder/releases/`; implementation detail: linked issues/plans.

## Past

- **Latest session: 0.29.1 published, and the site got its own mark.**
  - RubyGems `harnex 0.29.1`, tag `v0.29.1` (on `875b2b1`), `main` pushed;
    reinstalled from RubyGems. Record: `koder/releases/0.29.1.md`.
  - Site: the MDI console icon gave way to a harnex mark (a prompt pane
    beside two worker panes, Holm `deep` style) and a hand-made 1200x630
    social card (`site/card.rb` → `site/src/assets/og.png`, named in
    `og:image`). Redeployed with the 0.29.1 docs; feedback form logo
    re-uploaded. How-to: `site/README.md`.
  - Checked: harnex needs nothing for new Pi models. `model: zai/glm-5.3`
    passes straight to `pi --model` (live ask ok, cost reported by Pi).
- **Previous session (no harnex code change): downstream docs caught up.**
  - pi repo harnex skill (`~/Projects/pi` = `pi-config`, commit `e2f6980`):
    needs >= 0.29.1, documents `--phase`, points to `harnex doctor` /
    `harnex mcp install` / the site, evals use the lane verbs.
  - Holm Issue 1050 filed (Holm `8027a8691`): Holm's `knowledge-base/`
    dispatch docs still teach `harnex run codex`; the issue holds the 0.29.1
    lane facts, a line-level inventory and three owner decisions (lane
    worktrees vs Holm's sibling-worktree rule first).
- **0.29.1** fixes #88, where a repo phase allowlist with `"policy":
  "reject"` refused every lane. Lanes now run under the harnex-owned phases
  `delegate`/`ask` and accept `--phase NAME`.
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

- **Owner direction (2026-10-23):** harnex work pauses until Holm starts
  using lanes (Holm Issue 1050); come back with what Holm's usage surfaces.
- **Public = local = 0.29.1:** RubyGems, tag `v0.29.1`, GitHub `main` and
  the site.
- **Holm runs `"policy": "reject"`** (Holm `35e126858`), which needs 0.29.1:
  any other machine still on 0.29.0 needs `gem update harnex`.
- **#89 is open (filed after the last handoff, from Holm's first lane
  use):** lane names collide across sibling worktrees of a bare repo, so
  `result NAME` fails; and the `gpt` relay invented a `worktree` from brief
  prose. Cause and fixes: `koder/issues/89_lane_names_collide_across_bare_worktrees.md`.
- **pi repo is 18 commits ahead of `origin/master`, unpushed** (includes a
  merge of the other machine's "Make it work with claude"). Pushing is the
  owner's call.
- **Owner direction:** exclusively Pi + GPT models. Releases are local only
  (suite green → version/CHANGELOG → `gem build` → `gem install --local` →
  smoke → `koder/releases/<v>.md` → STATE) unless the owner approves
  publishing; 0.29.0 was approved and published. Run `pi update` first.
- **Site:** after a docs change, run `ruby site/build.rb`, then
  `holm @zyt app deploy site/app --spec-v1 --host harnex.zyt.app --force`.
  - Feedback project `6jyd3ya4`: the form's logo is `site/app/web/icon-512.png`
    (re-uploaded 2026-10-25 with the new mark). Re-upload it if the mark
    changes.
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

0. **#89** (first Holm lane friction): one lane namespace per bare repo,
   names unique across open lanes, `agents/gpt.md` carries `cwd:` into
   `result`/`reply` and never infers `worktree`. Keep folding Holm Issue
   1050 friction into harnex issues.
1. **#86 slice 3 rest:** automatic capacity retry/fallback for `delegate`
   and `run` (with #59/#82).
2. **Eval follow-ups:**
   - an Opus-supervisor round;
   - worktree bootstrap for repos that need `.env` or dependencies;
   - rerun `evals/agents/run` after any agent-facing change.
3. **Site follow-ups:**
   - check it in Safari and Firefox, and as an installed app on a phone;
   - check the new link preview in a real unfurler (Slack, X, iMessage).
4. #41 Slice C (`docs/public_api.md`), #78 pane time markers, #17, #16
   (macOS), #59.
