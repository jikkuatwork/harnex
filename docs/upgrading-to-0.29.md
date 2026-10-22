# Upgrading to 0.29

harnex 0.29 is the agent release. It adds lanes (`delegate`, `result`,
`reply`, `land`, `discard`, `lanes`), the `harnex mcp` server and the `gpt`
subagent for Claude Code. The low-level session commands (`run`, `send`, `wait`,
`watch`, `stop`, `status`, `pane`, `logs`, `events`) keep working as before.

The last RubyGems release before this one was 0.12.0. If you are upgrading
from it, read the whole page; from 0.21 on, only the 0.22 section applies.

```bash
gem install harnex          # 0.29.0
harnex --version
harnex doctor               # checks Pi; reports MCP and agent integrations
harnex mcp install          # optional: native tools for Claude Code and Pi
pi update                   # harnex needs Pi 0.80.4+; MCP features want 1.0.4+
```

## Breaking changes

### Codex support was removed (0.20)

harnex now runs Pi workers backed by GPT and other models; Pi's structured RPC
mode is the worker path that is designed, tested and supported. Removed:

- the `codex` and `codex app-server` adapters and the JSON-RPC session
  transport;
- `harnex run --fast` and `--legacy-pty`, and `harnex preflight --legacy-pty`;
- the Codex checks in `harnex doctor` (it checks Pi; `--adapter pi|all`).

`harnex run codex` is no longer special-cased; it wraps a `codex` binary as a
generic PTY program. Claude Code, OpenCode and any other terminal CLI still run
under a PTY as before. Dispatch rows keep their schema; Codex-only fields stay
`null` in new rows.

### `harnex ask` waits 9 minutes by default (0.22)

`ask` used to wait without a limit. It now stops waiting after 9 minutes (the
worker keeps going) and exits 124, naming `harnex result ID`, which keeps
waiting and prints the answer. Pass `--timeout none` for the old behavior.
`ask --resume ID` still works and no longer needs `--repo`.

### Pi starts with `--no-approve` (0.22)

Pi's RPC mode cannot show its project-trust prompt, so harnex now starts every
Pi worker with `--no-approve`: project-local Pi resources (`.pi/` extensions,
skills, prompts) are ignored unless you pass `-- --approve`. Before, the result
depended on Pi's default.

### Workers never see harnex's own MCP tools (0.25)

When harnex is registered as an MCP server in Pi, every Pi worker harnex
starts gets `--exclude-tools mcp__harnex__…`, and a read-only ask worker gets
`--no-mcp`. A worker can no longer start other workers. Your own `--tools`
and `--exclude-tools` still apply (the exclusions are merged).

## What's new, briefly

- **Lanes** — `delegate` hands a task to a worker (optionally in its own git
  worktree) and prints its reply with a footer of state, model, cost, commits
  and next steps. `result` collects parallel lanes, `reply` follows up with the
  worker's context (a finished lane resumes its Pi session), `land` merges and
  cleans up, `discard` drops a lane, `lanes` shows what each worker is doing.
  See [Lanes](lanes.md).
- **`harnex mcp`** — the same verbs as native MCP tools for Claude Code, Pi and
  any MCP client, with progress notifications for long calls. See
  [MCP server](mcp.md).
- **The `gpt` subagent** for Claude Code, installed by `harnex mcp install`.
  See [Coding agents](agents.md).
- **Hygiene** — harnex adds `.harnex/` to the clone's `.git/info/exclude`, so
  lane worktrees and dispatch rows never show up as untracked work.
- **`harnex doctor`** reports `integrations` (MCP registrations, the agent)
  and new capabilities (`lanes`, `mcp`, `ask_resume`).
- **`wait --since TIME`** ignores events from an earlier launch of a reused
  session id.

## If something looks different

| You see | Why | Do |
| --- | --- | --- |
| `ask` exits 124 after 9 minutes | new default wait | `harnex result ID`, or `--timeout none` |
| A Pi worker ignores `.pi/` resources | `--no-approve` by default | `harnex run pi ... -- --approve` |
| `harnex run codex` behaves like a plain PTY program | Codex adapters removed | use Pi workers (`harnex delegate`, `harnex run pi`) |
| A new `.harnex/` line in `.git/info/exclude` | harnex hides its own state | nothing; it is local to the clone |
| Workers lack `mcp__harnex__*` tools | recursion guard | intended |

The full history is in the [changelog](../CHANGELOG.md).
