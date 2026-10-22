# Lanes

A **lane** is one Pi worker doing one job: a question, a task, or a task plus
its follow-ups. You start one with `harnex ask` or `harnex delegate`, collect
it with `harnex result`, continue it with `harnex reply`, and finish it with
`harnex land` or `harnex discard`. Every lane has a name, runs in a visible
tmux window named after it, and leaves a small record so any later command can
find it by name from anywhere in the repository.

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
- **Without `--worktree`** the worker works in the current directory, which is
  right for tasks that only run or inspect things (tests, a benchmark, a long
  command). `--name NAME` names the lane; otherwise harnex derives a name from
  the task (`pi-slow-bench`).
- **`--file PATH`** reads a long brief from a file. Briefs must be
  self-contained: the worker has not seen your conversation. Name the files, the
  expected behavior and how to verify it.
- **`--model provider/model`** and **`--effort low|medium|high`** pick the
  model; the default is Pi's own default model.

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

## When a model fails

```text
── word-count: FAILED after 3s (API error (404): model_not_found) · gpt-9 · $0.00 · 0 commits
   next: `harnex reply word-count "Continue the same task from where you stopped" --model openai/gpt-5.1`
         (keeps the task; another model) or `harnex discard word-count`
```

For provider and model failures (not found, rate limited, out of capacity) the
footer suggests continuing on Pi's default model. `reply --model` resumes the
same session, so the task is not lost. For `ask`, `--fallback-model` does this
automatically.

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
never records tool arguments). `harnex pane --id NAME --lines 40` captures the
worker's tmux window, and the window itself is always there to watch.

## Where things live

- **Lane records:** `~/.local/state/harnex/lanes/` (one JSON file per lane:
  repo, worktree, branch, model, owner, Pi session, cost, last result). Closed
  lanes are pruned after 30 days; open lanes never are.
- **Worktrees:** `.harnex/worktrees/NAME` inside your repository, on branch
  `harnex/NAME`.
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
