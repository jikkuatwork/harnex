# MCP server

`harnex mcp` serves the [lane](lanes.md) commands as native
[Model Context Protocol](https://modelcontextprotocol.io) tools over stdio.
Claude Code, Pi and any other MCP client can then hand work to Pi workers
without shelling out, quoting a brief, or looping on exit codes.

```bash
harnex mcp install     # register for Claude Code (user scope) and Pi
harnex mcp status      # where it is registered
harnex mcp uninstall   # remove both registrations
```

Restart running Claude Code and Pi sessions afterwards: clients load MCP
servers when a session starts. `harnex doctor` reports the registrations under
`integrations`.

## Tools

Each tool runs the matching CLI command and returns its text: normally the
worker's reply followed by the `── NAME:` footer. `lanes` returns the
`harnex lanes` table, with each worker's live activity; a settled worker reads
"finished, uncollected" until its result is collected. Scripts use
`harnex lanes --json`, whose `state` is `done`/`failed` for a settled worker
(never `running`), with separate `collected` and `live` fields.

| Tool | Arguments | Does |
| --- | --- | --- |
| `ask` | `question`; `model`, `effort`, `fallback_model`, `write`, `cwd`, `wait_minutes` | A read-only answer from a Pi worker |
| `delegate` | `task`; `worktree`, `name`, `wait`, `model`, `effort`, `cwd`, `wait_minutes` | A worker does the task (in a worktree when `worktree` is set) |
| `result` | `names`; `cwd`, `wait_minutes` | Wait for lanes and return each result |
| `reply` | `name`, `message`; `model`, `wait`, `cwd`, `wait_minutes` | Follow-up to the same worker, which keeps its context |
| `land` | `names` (optional); `cwd` | Merge worktree lanes, remove worktrees and branches |
| `discard` | `names`; `cwd` | Drop lanes without merging |
| `lanes` | `all`; `cwd` | Open lane JSON: settled state, collection, liveness, model and branch |

Arguments are forgiving: `prompt`, `brief` or `message` work for `task`;
`prompt` or `query` for `question`; `lane` or `id` for `name`. `cwd` defaults
to the server's working directory, which MCP clients set to the project.

## Long calls

A blocking call (`ask`, `delegate`, `reply`, `result`) waits up to
`wait_minutes` (default 25) and then returns "still working" with the lane name;
the worker keeps going and `result` collects it. While it waits, the server
sends `notifications/progress` every 15 seconds:

```text
word-count: working 2m10s · 7 tool calls · now bash 12s
```

Progress resets the clients' idle timers (Claude Code's 30-minute stdio idle
timeout, Pi's per-request timeout), and Claude Code shows it under the running
tool call.

- **Claude Code, main conversation:** a call still running after two minutes
  moves to a background task on its own; Claude keeps working and is notified
  when the result lands. A plain `delegate` therefore behaves like a background
  subagent.
- **Claude Code subagents and headless runs** block on the call. Headless
  `claude -p` stops background work ten idle minutes after the main turn ends;
  set `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` for longer unattended runs.
- **Pi:** `harnex mcp install` registers the server with `exposure: direct`
  (the tools are declared to the model like built-ins) and a two-hour request
  timeout.
- **Cancelling** a call (for example pressing Esc) stops the wait, not the
  worker; `lanes` and `result` still see it.

Calls run concurrently, so a client can start several `delegate` calls with
`wait: false` and collect them with one `result`.

## Workers never get harnex's tools

Pi keeps MCP tools even when a worker is limited with `--tools`, so a worker
started by harnex would otherwise see `delegate` and could start more workers,
or escape a read-only ask. harnex prevents both: every Pi worker starts with
`--exclude-tools mcp__harnex__…`, and a read-only ask worker starts with
`--no-mcp`.

## Other clients

Any client that speaks MCP over stdio can run the server. The command is the
`harnex` executable with the argument `mcp`. Prefer the absolute path of the
RubyGems wrapper, `$(ruby -e 'print Gem.bindir')/harnex`, which is what
`harnex mcp install` registers, so no version-manager shim or working
directory gets in the way:

```json
{
  "mcpServers": {
    "harnex": { "command": "/path/to/bin/harnex", "args": ["mcp"] }
  }
}
```

The server negotiates MCP protocol revisions 2024-11-05 through 2025-11-25
and declares only the `tools` capability.

## Troubleshooting

- **The tools don't appear:** restart the client session; check
  `harnex mcp status` and, for Pi, `pi mcp list`.
- **A call ends with "still working":** that is the wait limit, not a failure;
  call `result` with the lane name.
- **A worker failed on its model:** the footer suggests
  `reply` with another `model`, which keeps the task.
