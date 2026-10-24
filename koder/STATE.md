# Harnex State

Updated: 2026-10-25 | 02:22 AM | IST

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
- **Previous session:** pi repo harnex skill updated for 0.29.1 (`e2f6980`);
  Holm Issue 1050 filed (Holm `8027a8691`) for Holm's codex-era dispatch
  docs and the lane-worktree decisions.
- **0.29.0, the agent release** (first public since 0.12.0): lane docs, the
  `gpt` agent in the gem, and https://harnex.zyt.app (`site/build.rb`, app
  `holm_app_wQ4TB6JUhrTZ` on peer `zyt`). Record: `koder/releases/0.29.0.md`.
- **#87 agent smoothness, done on 0.22.0–0.28.0:** the lane verbs, `harnex
  mcp`, the `gpt` agent; two clean 28/28 eval rounds (Claude Code and Pi,
  with and without MCP). Plan: `koder/plans/39_agent_smoothness.md`; evals:
  `evals/agents/run`.
- #86 slices 1–2 are done; slice 3's capacity fallback is still open.

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
  publishing, as for 0.29.0 and 0.29.1. Run `pi update` first.
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
