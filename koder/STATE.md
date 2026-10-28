# Harnex State

Updated: 2026-10-28 | 12:27 PM | IST

Thin session handoff. History: `CHANGELOG.md`; release evidence:
`koder/releases/`; implementation detail: linked issues/plans.

## Past

- **#93 implemented, not released:** honest lane JSON/MCP settlement and
  distinct provider refusal/no-details outcomes. Evidence:
  `koder/issues/93_dead_lanes_read_running_and_refusals_read_unknown.md`;
  `CHANGELOG.md` Unreleased.

- **Latest release: 0.30.0 published (RubyGems, tag `v0.30.0`, GitHub,
  site), fixes Holm's lane friction #89–#92** (Holm Queue 167). Record:
  `koder/releases/0.30.0.md`.
  - #89: a bare layout (`.bare` + sibling worktrees) is one lane namespace;
    generated names skip names in flight anywhere, chosen names are refused
    while another repo's worker runs; lanes in another worktree are named
    after it; `gpt` agent: `name:` header, `cwd:` follows
    `result`/`reply`, never a `worktree` from prose.
  - #90: `.harnex/config.json` `lanes.worktree_path`/`lanes.branch`
    templates (e.g. `../{name}`); `land`/`discard` follow them.
  - #91: in-place footers count only the worker's commits.
  - #92: results list interjected `send`s and the answers they replaced.
  - pi repo: agent + skill updated and pushed (`0f5567b`, `58c1144`).
  - Configuration docs gained a *Lane worktrees* section.
- **Before that:** 0.29.1 published with the site's own mark; Holm Issue
  1050 filed (Holm `8027a8691`); 0.29.0, the agent release, put the `gpt`
  agent in the gem and launched https://harnex.zyt.app (records in
  `koder/releases/`).
- **#87 agent smoothness, done on 0.22.0–0.28.0:** the lane verbs, `harnex
  mcp`, the `gpt` agent; two clean 28/28 eval rounds (Claude Code and Pi,
  with and without MCP). Plan: `koder/plans/39_agent_smoothness.md`; evals:
  `evals/agents/run`.
- #86 slices 1–2 are done; slice 3's capacity fallback is still open.

## Present

- **#93 worktree ready for review/landing** (`harnex/i93-lane-state-refusals`);
  full suite passes (opt-in live Pi integration not run). No version bump,
  publication or site deployment in this task; public/local stay 0.30.0.

- **Owner direction (2026-10-23):** harnex work follows Holm's lane usage
  (Holm Issue 1050); fold what it surfaces into harnex issues.
- **Local = public = 0.30.0** (RubyGems, tag `v0.30.0`, GitHub `main`,
  https://harnex.zyt.app).
- **Holm picks up 0.30.0 only after `/mcp` reconnects harnex or the session
  restarts** (running MCP servers and agent definitions load at start).
  Holm was told; whether to add `lanes` templates to its tracked
  `.harnex/config.json` is Holm's decision.
- **Holm runs `"policy": "reject"`** (Holm `35e126858`), which needs 0.29.1:
  any other machine still on 0.29.0 needs `gem update harnex`.
- **pi repo:** in sync with `origin/master`, except an uncommitted
  `.pi/skills/feedback/references/01_usage.md` change that is not harnex's.
- **Owner direction:** exclusively Pi + GPT models. **Every release is
  published and installed immediately, with the site** (2026-10-25; the
  local-only rule is retired): the full CLAUDE.md checklist, then the site
  build and deploy below. Run `pi update` first.
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

0. **Review/land #93, then watch Holm's next lane runs** (Holm Issue 1050).
   #92's optional ask (refuse direct `send` to a lane
   another session owns) is not done.
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
