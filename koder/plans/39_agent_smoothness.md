# Plan 39 — Agent smoothness (issue #87)

Owner mandate (2026-10-22): work autonomously until harnex is "butter
smooth with agents"; breaking changes allowed; local releases as often as
needed. This plan holds the bar, the evidence and the design. Iterate:
change → release locally → rerun the evals → compare.

## Smoothness bar (definition of done)

Measured by `evals/agents/run` (real supervisors against a fresh
`evals/agents/fixture` repo; results in `~/.cache/harnex-evals/`).

1. **Correct:** every scenario passes for every supervisor route
   (Claude Code + CLI, Claude Code + MCP, Pi + CLI, Pi + MCP), on two
   consecutive full runs.
2. **No reading required:** zero doc lookups beyond the skill front door
   (no `agents-guide`, no `--help`, no second skill).
3. **Few calls:** harnex calls ≤ S1 1, S2 2, S3 5, S4 3, S5 3, plus the
   supervisor's own verification.
4. **No harnex-caused errors:** no failed tool call caused by harnex
   output, flags or state. Model slips such as a misspelled tool name
   don't count.
5. **No leftovers:** no untracked files, worktrees, branches the supervisor
   didn't ask for, or live sessions after the task.
6. **Long tasks are invisible:** S4 needs no special handling by the
   supervisor beyond the documented one-command continuation.

## Baseline (0.21.0, 2026-10-22)

`~/.cache/harnex-evals/baseline-0.21.0`; Claude Sonnet and Pi on
gpt-6.1-sol; all 10 runs pass.

| Scen | Sup | Time | Calls | harnex | Err | Docs | Left |
|---|---|---|---|---|---|---|---|
| S1 | claude | 56s | 1 | 1 | 0 | 0 | 0 |
| S1 | pi | 111s | 6 | 3 | 0 | 4 | 0 |
| S2 | claude | 100s | 5 | 1 | 0 | 0 | 1 |
| S2 | pi | 222s | 17 | 7 | 0 | 6 | 1 |
| S3 | claude | 252s | 17 | 3 | 2 | 0 | 0 |
| S3 | pi | 310s | 25 | 11 | 0 | 6 | 1 |
| S4 | claude | 695s | 1 | 1 | 0 | 0 | 1 |
| S4 | pi | 815s | 15 | 5 | 1 | 6 | 1 |
| S5 | claude | 111s | 8 | 4 | 0 | 3 | 1 |
| S5 | pi | 164s | 18 | 7 | 0 | 6 | 1 |

Friction found:

- **F1 `.harnex/` litter:** `.harnex/dispatch.jsonl` is left untracked in
  every write repo and in lane worktrees, so `git worktree remove` fails
  (S3/claude).
- **F2 Doc hunting:** Pi reads the skill, its index, three `agents-guide`
  topics, `run --help` and the git-worktree skill before acting (4–6
  lookups). The skill points to a long guide instead of carrying the
  fast path.
- **F3 Hand-built lanes:** supervisors create worktrees, branches and brief
  files themselves, then compose 10–14 flag `harnex run` lines
  (`--id`/`--tmux` duplicated, `--owner-tag`, `--root`, `-- --no-approve`).
- **F4 Raw JSON:** `run --wait-done` output is nested JSON; 124 from a
  long run reads as an error; Pi then reads receipts and stdout files.
- **F5 No landing step:** merging lanes back and cleaning worktrees and
  branches is manual, including conflict handling.
- **F6 Follow-ups need a live lane:** the `gpt` relay auto-stops, so a
  follow-up reaches a fresh worker without context. CLI follow-ups need
  the supervisor to know not to pass `--auto-stop`.

## Design

### A. Agent layer (CLI): a few verbs, text output, lanes by name

- `harnex ask QUESTION`: unchanged (read-only answer).
- `harnex delegate TASK [--worktree [NAME]] [--cwd DIR] [--model M]
  [--effort E] [--fallback-model M] [--name NAME] [--file PATH]
  [--no-wait] [--timeout DUR] [--json]`
  - `--worktree NAME` creates `.harnex/worktrees/NAME` on branch
    `harnex/NAME` from HEAD. Without `--worktree`, the worker writes in
    the current checkout.
  - Prints the worker's reply, then a lane footer: name, state, time,
    model, cost, branch, commits, diffstat, and the next commands.
  - Exit codes: 0 done, 1 failed, 124 still working; the footer names
    `harnex result NAME`.
- `harnex result [NAME...] [--timeout DUR]`: block until those lanes (or
  all of the caller's running lanes) report. Prints each result as it
  lands, with the same format. It replaces `ask --resume`, which stays as
  an alias.
- `harnex reply NAME MESSAGE [--no-wait] [--timeout DUR]`: follow-up. A
  live lane takes it at once. A lane that has exited is relaunched on its
  own Pi session (`pi --session <agent_session_id>`), so context carries
  over without idle workers.
- `harnex land NAME`: merge `harnex/NAME` into the current branch, then
  remove the worktree and branch and stop the session. On conflict, leave
  git's merge in progress, list the files, and finish cleanup on the next
  `land` once it's resolved.
- `harnex discard NAME`: stop, then remove the worktree and branch
  without merging.
- `harnex lanes`: the caller's lanes, with state, age, model, branch and
  last activity.
- **Lane registry** `STATE_DIR/lanes/<repo_key>--<name>.json`: kind, repo
  root, cwd, worktree, branch, base sha, model, owner, session ids. Verbs
  resolve a name by repo first, then globally if unique.
- **Hygiene:** any harnex write into a git repo ensures `.harnex/` is
  listed in `<git-common-dir>/info/exclude` (F1). `--no-approve` becomes
  the Pi adapter default.

### B. `harnex mcp` (stdio MCP server)

- **Tools:** `ask`, `delegate`, `result`, `reply`, `land`, `discard`,
  `lanes`. Arguments mirror the CLI and results are the CLI text.
- **Blocking with progress:** blocking calls send `notifications/progress`
  every ~15s (lane state and last activity). That resets Claude Code's
  stdio idle timeout (30m) and Pi's per-request timeout (60s). Claude Code
  moves a main-session call to the background after 2m and notifies on
  completion; subagent calls simply block.
- **Concurrency:** calls run concurrently (thread per `tools/call`;
  serialized stdout); `notifications/cancelled` stops waiting, not the
  worker.
- **Install:** `harnex mcp install` registers the server for Claude Code
  (`claude mcp add -s user harnex -- harnex mcp`) and Pi
  (`~/.pi/agent/mcp.json`, `exposure: direct`, long `timeout`).
  `harnex doctor` reports both.

### C. Front doors

- **Skill:** rewrite the `harnex` skill so the front door is the whole
  fast path. Prefer MCP tools when they're present; otherwise, the five
  verbs. No `agents-guide` needed for normal use.
- **`gpt` agent:** relay over MCP tools (`mcpServers: [harnex]`), so there
  is no heredoc, no 124 loop, and `reply` keeps the lane's context.
- **`agents-guide claude`:** a short page that leads with the agent layer.

## Phases (each ends with a local release + eval run)

1. **0.22.0:** agent layer (A) + hygiene + skill rewrite. Evals: claude,
   pi.
2. **0.23.0:** `harnex mcp` + install + `gpt` agent on MCP. Evals add
   claude-mcp and pi-mcp routes.
3. **0.24.0+:** fix what the evals show. Candidates: capacity fallback
   for `delegate`, faster rate-limit surfacing, cost in footers, progress
   detail, more scenarios (failure handling, mid-run progress check,
   review of a diff).

## Out of scope

- Codex or any non-Pi worker path (owner decision 2026-10-20).
- RubyGems publication, tags and pushes (local installs only).
- Changing the low-level `run`/`send`/`wait`/`watch` contracts beyond
  defaults (`--no-approve`). They stay for queue and koder workflows.

## Progress log

- **0.22.0, lanes** (`r1-0.22.0`):
  - 9/10 pass; leftovers 8 → 0; Claude S3 252s → 101s.
  - Remaining: the Bash `gpt` relay ran a task itself (S4); Pi doc hunting
    was driven by its AGENTS.md `--id`/`--tmux` directive.
- **0.23.0, MCP** (`r2-0.23.0`, four routes, 5 scenarios):
  - 20/20 pass, 0 doc lookups. Pi calls: S2 17 → 10–11, S3 25 → 11–17.
  - Remaining: a `git merge` by hand left worktrees (S3/claude); 124
    continuations counted as errors.
- **0.24.0:** hand-merge sweep, progress detail, model-failure footer, S6/S7
  scenarios. Evals: `r3-0.24.0`.

Bar revision: call budgets are measured against the minimal path. S3 is 3
delegates + 1 result + up to 3 lands (landing one by one with checks
between is good practice); S5 is delegate + reply + land.
- **0.25.0:** workers never get harnex MCP tools (a read-only ask worker had
  delegated a writable lane). Round r4: 28/28 pass, 0 leftovers; one harnex
  usage error (`land {}`).
  - Interactive Claude Code verified: an MCP `delegate` call auto-backgrounded
    and Claude was notified on completion.
  - The headless S4 failure was `claude -p`'s 10-minute background ceiling;
    the evals lift it.
- **0.26.0:** bare `land`; doctor `integrations`. Round A (r5): 27/28; fixes
  in 0.27.0 (MCP argument synonyms; the `gpt` agent names `harnex lanes`).
- **0.27.0:** rounds B and C must both meet the bar (r6, r7).

