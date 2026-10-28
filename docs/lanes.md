# Lanes

A **lane** is one Pi worker doing one job: a question, a task, or a task plus
its follow-ups. You start one with `harnex ask` or `harnex delegate`, collect
it with `harnex result`, continue it with `harnex reply`, and finish it with
`harnex land` or `harnex discard`. Every lane has a name, runs in a visible
tmux window named after it, and leaves a small record so any later command can
find it by name from anywhere in the repository (from any worktree of it, a
bare-repo layout included).

Lanes are the agent-facing layer of harnex. Everything here is also available
as native tools through [`harnex mcp`](mcp.md), and the low-level `run`, `send`,
`wait` and `watch` commands remain underneath for custom orchestration.

| Need | Command |
| --- | --- |
| A second opinion, an explanation, a read-only review | `harnex ask "QUESTION"` |
| A task that edits code | `harnex delegate --worktree NAME "TASK"`, review, then `harnex land NAME` |
| A task that only runs or inspects things | `harnex delegate "TASK"` |
| Several tasks in parallel | `harnex delegate --no-wait --worktree NAME "TASK"` per task, then `harnex result` |
| More work for the same worker, with its context | `harnex reply NAME "MESSAGE"` |
| Throw a lane away | `harnex discard NAME` |
| What is open and what each worker is doing | `harnex lanes` |

## Ask

```bash
harnex ask "Which module writes dispatch rows, and is the lane case tested?"
harnex ask --model openai/gpt-5.1 --file /tmp/review.md
```

The worker reads the repository with read-only tools (`read`, `grep`, `find`,
`ls`), answers, and stops. It cannot run commands or change anything; for
that, use `delegate`. stdout is the answer; stderr gets one line naming the
lane, its time and the model. `--write` lets the worker edit and run commands,
and `--fallback-model M` asks once more with another model when the first one
is out of capacity or rate limited.

Every ask is a lane (`pi-ask-xxxx`), so `harnex reply pi-ask-xxxx "..."` asks a
follow-up of the same worker, with everything it read still in context.

## Delegate

```bash
harnex delegate --worktree word-count \
  "Add TextKit.word_count(text): the number of whitespace-separated words, with a test. Run bin/test."
```

The worker edits files, runs commands, and replies with a summary. harnex
prints that reply and then a footer:

```text
Committed as `a6bf91e` on `harnex/word-count`.
- Added `TextKit.word_count(text)` in `lib/textkit.rb`.
- Ran `bin/test`: 3 tests, 6 assertions, all passing.

── word-count: done in 49s · gpt-5.1 · $0.03 · 1 commit, 2 files (+12 -0)
   worktree .harnex/worktrees/word-count (branch harnex/word-count)
   next: review `git diff HEAD...harnex/word-count`, then `harnex land word-count` ...
```

The footer always says what happened and what to do next: state, time, model,
cost, commits and the next commands.

- **`--worktree NAME`** creates `.harnex/worktrees/NAME` on a new branch
  `harnex/NAME` from `HEAD`. The worker is told to commit there. Parallel lanes
  never collide, and your checkout is untouched until you land. If your checkout
  has uncommitted changes, harnex warns that the worktree starts from `HEAD`.
  A repo that keeps its worktrees elsewhere says so in `.harnex/config.json`
  (see [Where things live](#where-things-live)).
- **Without `--worktree`** the worker works in the current directory, or in
  `--cwd DIR`, which is right for tasks that only run or inspect things (tests,
  a benchmark, a long command) and for a worktree you made yourself.
- **Names.** `--name NAME` names the lane. Otherwise a lane working in another
  worktree of the repo is named after it (`--cwd ../night-1024_s3` gives
  `pi-night-1024_s3`), and any other lane after the task's first words
  (`pi-slow-bench`, then `pi-slow-bench-2`). Generated names skip every name
  another lane still holds anywhere (working, uncollected, or a worktree not
  yet landed), and a name you choose is refused while another repo's worker
  is running under it, so `harnex result NAME` and `reply NAME` find a
  working lane from anywhere.
- **`--file PATH`** reads a long brief from a file. Briefs must be
  self-contained: the worker has not seen your conversation. Name the files, the
  expected behavior and how to verify it.
- **`--model provider/model`** and **`--effort low|medium|high`** pick the
  model; the default is Pi's own default model.
- **`--phase NAME`** tags the lane's dispatch rows with a work phase (for
  example `implement`). Without it the phase is `delegate` (`ask` for an ask),
  which a repo's phase allowlist always accepts; a named phase is checked
  against the allowlist (see [configuration](configuration.md)).

### Waiting, and long tasks

Blocking commands (`ask`, `delegate`, `reply`, `result`) wait up to 9 minutes
by default, which fits under the 10-minute tool cap most coding agents have.
`--timeout DUR` changes it (`540`, `9m`, `1h30m`, or `none`).

| Exit code | Meaning |
| --- | --- |
| 0 | done |
| 1 | the worker failed (the footer says why and what to try) |
| 2 | usage error (nothing was started) |
| 124 | still working — the worker keeps going; run `harnex result NAME` |

```text
── slow-bench: still working (9m02s so far)
   keep waiting: harnex result slow-bench
```

`harnex result NAME` blocks again (another 9 minutes by default) and prints the
result in the same format once it lands, even if the worker finished between
calls.

## Review and land

```bash
git diff HEAD...harnex/word-count     # read the change
(cd .harnex/worktrees/word-count && bin/test)
harnex land word-count
```

`harnex land NAME` merges `harnex/NAME` into the current branch of the main
checkout, then removes the worktree and the branch. Leftover uncommitted
changes in the lane are committed first. `harnex land` with no name lands every
finished worktree lane you started in this repo, oldest first.

**Conflicts.** When the merge conflicts, git's merge is left in progress and
harnex lists the files. Resolve them, `git add` them and `git commit`, then run
`harnex land NAME` again to clean up (or `git merge --abort` to give up).
Several lanes that touched the same file land one at a time.

**Merging by hand** works too. A lane whose branch is already in `HEAD` (and
whose worktree is clean) is tidied up by the next `delegate`, `result`, `lanes`
or bare `land`.

`harnex discard NAME` stops the lane if it is still working and deletes its
worktree and branch without merging.

**Lanes in place.** For a lane without a worktree, the footer counts only the
commits the worker made (harnex watches `HEAD` around each git command the
worker runs). Commits someone else made in the same checkout meanwhile are
named apart: `0 commits (HEAD also moved 3 commits by others)`.

## Parallel lanes

```bash
harnex delegate --no-wait --worktree slugify  "Fix TextKit.slugify so punctuation is dropped ..."
harnex delegate --no-wait --worktree truncate "Add TextKit.truncate(text, n) ..."
harnex delegate --no-wait --worktree titleize "Add TextKit.titleize(text) ..."
harnex result          # waits for all three, printing each result as it lands
harnex land            # lands every finished worktree lane, oldest first
```

`harnex result` with no names covers every lane you started in this repo whose
result you have not collected yet. Name lanes to wait for specific ones.
"You" is the calling agent session (`CLAUDE_CODE_SESSION_ID` or
`PI_SESSION_ID`); a Claude Code subagent shares its parent's id, so a subagent
should name the lanes it waits for.

## Follow-ups

```bash
harnex reply word-count "Also add TextKit.char_count(text), in the same style, with a test."
```

The worker keeps its context. A worker still on its turn takes the message
mid-task as a follow-up; a lane that has finished is relaunched on its own Pi
session (`pi --session`), so it remembers everything from the earlier turns.
The footer's cost is the lane's total so far.

**Messages from someone else.** Anyone can `harnex send` to a lane's worker
(the owner from another terminal, a buddy). The lane's result then says so,
so the session that started the lane is not left guessing:

```text
[earlier reply this turn, before another message reached the worker]
Review: PASS (0 P1, 2 P2) ...

[latest reply]
Understood; the report is now in /tmp/review.md.

── review: done in 6m10s · gpt-6.1-sol · $0.41 · 0 commits
   interjected: 1 message reached the worker from outside this lane (the reply above may answer it; all: `harnex events --id review`):
     23:26:04 from a terminal (harnex send): "Write the report to /tmp/review.md instead"
```

The worker's earlier answers in the same turn (the original task's report
among them) come first; your own `harnex reply` follow-ups are never listed as
interjections.

## When a model fails

```text
── word-count: FAILED after 3s (API error (404): model_not_found) · gpt-9 · $0.00 · 0 commits
   next: `harnex reply word-count "Continue the same task from where you stopped" --model openai/gpt-5.1`
         (keeps the task; another model) or `harnex discard word-count`
```

For provider and model failures (not found, rate limited, out of capacity) the
footer suggests continuing on Pi's default model. `reply --model` resumes the
same session, so the task is not lost. For `ask`, `--fallback-model` does this
automatically on `provider_capacity` only.

A provider refusal is different: `policy_refusal` means the provider refused
the content, so a retry needs a rephrased brief or another route. Do not send
"Continue the same task" unchanged. `provider_error_unexplained` means Pi
reported exactly `Unknown error (no error details in response)`; read the
provider/gateway logs before retrying. Harnex does not infer a policy refusal
when Pi supplies no details.

## Watching a worker

```bash
harnex lanes
```

```text
NAME      STATE                  AGE    MODEL    BRANCH           NEXT
slugify   working (now bash 12s) 1m40s  gpt-5.1  harnex/slugify   harnex result slugify
truncate  done                   2m03s  gpt-5.1  harnex/truncate  harnex land truncate
```

A working lane shows the tool it is running right now (tool names only; harnex
never records tool arguments). `harnex lanes --json` and MCP `lanes` return
current settlement (`done`/`failed` even before collection), a separate
`collected` boolean, and process-liveness `live`. `collected: false` means
`harnex result` still needs to collect the turn; listing does not do that.
The table keeps `finished, uncollected` for those finished workers.
`harnex pane --id NAME --lines 40` captures the
worker's tmux window, and the window itself is always there to watch.

## Where things live

- **Lane records:** `~/.local/state/harnex/lanes/` (one JSON file per lane:
  repo, worktree, branch, model, owner, Pi session, cost, last result). Closed
  lanes are pruned after 30 days; open lanes never are.
- **Worktrees:** `.harnex/worktrees/NAME` inside your repository, on branch
  `harnex/NAME`. To keep them beside the main checkout instead, set templates
  in the repo's `.harnex/config.json` (`{name}`, `{yyyy}`, `{mm}`, `{dd}`;
  the path is relative to the main checkout). `land` and `discard` follow the
  lane's own path and branch:

  ```json
  { "lanes": { "worktree_path": "../night-{mm}{dd}_{name}", "branch": "night/{mm}{dd}_{name}" } }
  ```

- **Bare-repo layouts** (`repo/.bare` plus sibling worktrees): the main
  checkout is the worktree on the bare repo's `HEAD` branch (`master`), and
  every worktree of the repo shares its lanes.
- **`.harnex/`** is added to the clone's `.git/info/exclude` the first time
  harnex writes there, so lane worktrees and dispatch rows never show up as
  untracked work. Nothing tracked changes.

## Habits from `harnex run`

The lane commands accept the flags people and agents reach for from the
low-level `run`, instead of refusing them: `--id NAME` and `--tmux NAME` name
the lane, `--auto-stop` and `--wait-done` are what lanes do anyway,
`--wait-timeout` means `--timeout`, and `--context`/`--context-file` give the
task.

See also: [MCP server](mcp.md), [Coding agents](agents.md), and the CLI
reference (`harnex help delegate`, `result`, `reply`, `land`, `discard`,
`lanes`, `ask`).
