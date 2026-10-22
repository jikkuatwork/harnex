# Claude Code: GPT Workers as Tools

Harnex lets a Claude Code session or subagent hand work to Pi workers (GPT or
other provider models) and get the result back the way it calls any tool. Each
worker runs in a visible tmux window. Every command prints plain text: the
worker's reply, then a `── NAME: …` footer with the lane's state, model, cost,
commits and the next commands.

## Pick The Command

| Need | Command |
| --- | --- |
| A second opinion, an explanation, a read-only review | `harnex ask "QUESTION"` |
| One task done by a worker | `harnex delegate --worktree NAME "TASK"`, then `harnex land NAME` |
| Several tasks in parallel | `harnex delegate --no-wait --worktree NAME "TASK"` per task, then `harnex result` |
| A follow-up to the same worker | `harnex reply NAME "MESSAGE"` |
| Drop a lane | `harnex discard NAME` |
| What is open | `harnex lanes` |

Exit codes: 0 done, 1 failed, 2 usage error, 124 still working (the worker
keeps going; `harnex result NAME` keeps waiting).

### Ask

```bash
harnex ask "Which module writes dispatch rows, and is the lane case tested?"
harnex ask --model openai/gpt-5.1 --file /tmp/review.md
```

The worker reads the repository with read-only tools, answers, and stops.
stdout is the answer; stderr gets one line with the lane, its time and the
model. `--write` lets it edit and run commands; `--fallback-model M` asks once
more with another model after a provider-capacity failure.

### Delegate, Review, Land

```bash
harnex delegate --worktree word-count "Add TextKit.word_count(text) with a test; run bin/test"
git diff HEAD...harnex/word-count && bin/test   # your own check
harnex land word-count
```

`--worktree NAME` creates `.harnex/worktrees/NAME` on branch `harnex/NAME` from
`HEAD`. The worker is told to commit there. `harnex land NAME` merges the
branch into the main checkout's current branch, then removes the worktree and
branch; leftover uncommitted changes are committed first. On a merge conflict
the merge stays in progress: resolve, `git commit`, and run `harnex land NAME`
again to clean up. `harnex land` with no name lands every finished worktree
lane you started in this repo. `harnex discard NAME` drops the lane's work. Without
`--worktree`, the worker edits the current directory in place.

### Parallel Lanes

```bash
harnex delegate --no-wait --worktree slugify "Fix TextKit.slugify ..."
harnex delegate --no-wait --worktree truncate "Add TextKit.truncate ..."
harnex result            # waits for all your lanes, printing each as it lands
harnex land slugify && harnex land truncate
```

`harnex result` with no names covers every lane you started in this repo
whose result you have not collected; `harnex result NAME...` names them.

### Follow-Ups

```bash
harnex reply word-count "Also add TextKit.char_count(text) with a test."
```

A worker still on its turn takes the message as a follow-up. A finished lane
is relaunched on its own Pi session, so the worker keeps everything it knew.
After a provider-capacity failure, reply "Continue the same task from where
you stopped", optionally with `--model OTHER`.

## Rules For Claude Code

- **Long tasks.** Commands wait 9 minutes by default (`--timeout`), under the
  10-minute Bash cap. Give the Bash call `timeout: 600000`; the default 2
  minutes kills the wait. On 124 run `harnex result NAME` until it lands. In
  the main session you can also run the command with `run_in_background` and
  be notified.
- **Subagents** block in the foreground the same way; nothing needs a
  background notification. A subagent shares its parent's
  `CLAUDE_CODE_SESSION_ID`, so `harnex result` with no names also sees the
  parent's lanes; name the lanes you wait for.
- **Briefs are self-contained.** The worker has not seen the conversation.
- **Verify before you report success.** `done` means the worker's turn ended
  without error, not that the work is right. Check the diff and the tests.
- **Clean up.** Land or discard every worktree lane; `harnex lanes` lists what
  is still open.

## Low-Level Commands

`harnex run`, `send`, `wait`, `watch --owner` and `stop` remain for queues and
custom orchestration (see `harnex agents-guide dispatch` and `monitoring`).
Lanes are ordinary harnex sessions named after the lane.
