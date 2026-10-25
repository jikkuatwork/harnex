# Coding agents

harnex is built to be driven by coding agents: Claude Code, Pi, or anything
that can run a shell command or call an MCP tool. A supervising agent hands a
question or a task to a Pi worker (a GPT model by default), keeps working, and
gets the worker's reply back as plain text it can act on.

There are three ways in, from smoothest to most portable:

1. **MCP tools** (`harnex mcp install`): `ask`, `delegate`, `result`,
   `reply`, `land`, `discard` and `lanes` as native tools. See
   [MCP server](mcp.md).
2. **The `gpt` subagent** for Claude Code: a background subagent that relays
   one brief to a worker and returns the reply verbatim.
3. **The CLI** from any agent's shell tool: the same verbs as
   [lanes](lanes.md).

## Claude Code

### MCP tools (main conversation)

With the server registered, Claude calls the tools directly. A call that runs
longer than two minutes moves to the background on its own; Claude keeps
working and is notified when the result lands, so a `delegate` behaves like a
background subagent without one:

```text
❯ Use the harnex delegate tool to have a GPT worker run the slow benchmark and tell me the score.
● Calling harnex…
  ⎿  pi-slow-bench: working 59s · 3 tool calls · now bash 44s
● The GPT worker is still running the benchmark. I'll report the score when it finishes.
● MCP task (harnex/delegate) completed.
● The score is 302926.
```

### The `gpt` subagent

`harnex mcp install` also installs a `gpt` agent definition at
`~/.claude/agents/gpt.md` when none exists. It is a thin Haiku relay with only
the harnex tools: it never does the task itself and returns the worker's reply
exactly, footer included. Use it for parallel work (several `Agent` calls in
one message) and for follow-ups (`SendMessage` to the same agent reaches the
same worker, with its context).

```text
Agent(subagent_type: "gpt", prompt: """
worktree: word-count

Add TextKit.word_count(text) to lib/textkit.rb with a test; run bin/test.
""")
```

Optional header lines, then a blank line, then the brief:

| Header | Effect |
| --- | --- |
| `worktree: NAME` | Edit in a new worktree on `harnex/NAME`; land it afterwards |
| `mode: write` | Run commands or edit the current checkout in place |
| `mode: read` | Read-only, even if the brief mentions commands |
| `model: provider/model`, `effort: low\|medium\|high` | Pick the worker's model |
| `fallback: provider/model` | Retry a read-only ask on another model |
| `cwd: DIR` | Work in another directory, e.g. a sibling worktree (follow-ups stay there) |
| `name: NAME` | Name the lane (default: the `cwd` worktree's name, else the brief's first words) |

Without a header, questions and reviews go to a read-only worker, and a brief
that asks to run something or change files goes to a worker that can. Only
header lines set these: a brief that mentions a worktree or a branch is passed
on as it is, never turned into a `worktree`.
The definition ships with harnex as [`agents/gpt.md`](../agents/gpt.md).

### The CLI from Claude's Bash tool

```bash
harnex delegate --worktree word-count "Add TextKit.word_count(text) with a test; run bin/test."
```

Give the Bash call `timeout: 600000`: commands wait up to 9 minutes, and
Claude Code's default Bash timeout is two minutes. On exit 124 run
`harnex result NAME`. In the main conversation, `run_in_background` works too.

### Things worth knowing

- Claude Code loads agent definitions and MCP servers when a session starts;
  restart after `harnex mcp install`.
- Background results reach the parent XML-escaped (`&amp;`, `&lt;`). The relay's
  own text is exact.
- Headless `claude -p` stops background work ten idle minutes after the main
  turn; set `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` for long unattended runs.

## Pi

`harnex mcp install` adds the server to `~/.pi/agent/mcp.json` with
`exposure: direct`, so a Pi supervisor sees the tools like built-ins. Without
MCP, Pi uses the CLI through its `bash` tool; `harnex agents-guide claude` is
the short guide it needs (it applies to any supervising agent). Workers
started by harnex never see harnex's own MCP tools, so a worker cannot start
more workers.

## Habits that keep it smooth

- **Self-contained briefs.** The worker has not seen your conversation: name
  the files, the expected behavior and the check (`bin/test`).
- **A worktree for anything that edits.** `--worktree NAME` keeps parallel
  lanes apart and your checkout clean until you land.
- **Verify, then land.** `done` means the worker's turn ended without error,
  not that the work is right. Read the diff and run the tests yourself.
- **Land, don't merge by hand.** `land` also removes the worktree and branch.
- **Check on a worker with `lanes`.** It shows the tool each worker is running
  now.

## Measuring it

`evals/agents/run` drives real supervisors (Claude Code headless and Pi print
mode, each with and without MCP) through seven scenarios against a fixture
repository and scores correctness, tool calls, harnex usage errors, doc
lookups and leftovers. harnex 0.29 passes all 28 runs with no harnex usage
errors, no doc lookups and nothing left behind.

```bash
evals/agents/run --list
evals/agents/run --supervisor claude,pi S2 S3
```
