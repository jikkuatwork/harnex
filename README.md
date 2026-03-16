# Harnex

If you use AI coding agents in the terminal — Claude Code, Codex,
or similar — and you've ever wished you could run two of them at once
and have them coordinate, that's what harnex does.

One agent writes code. Another reviews it. A third implements a
different feature in a separate worktree. You watch them work in
tmux windows, or let them run in the background. They find each
other, send messages, queue work, and report back — without you
copy-pasting between terminals.

```
  You
   │
   ├── harnex run codex --id worker --tmux
   ├── harnex run claude --id reviewer --tmux
   │
   ├── harnex send --id worker --message "implement auth"
   │     └── worker finishes, reviewer picks it up
   │
   └── harnex status
         worker   codex   prompt
         reviewer claude  busy
```

## When you'd want this

- You're working on a codebase and want to parallelize across
  agents — one implements, one reviews, one tests
- You want a supervisor agent that spawns workers, gives them
  tasks, and collects results
- You're tired of switching between terminal tabs to copy output
  from one agent into another
- You want agents to coordinate without you being the middleman

## When you wouldn't

- You only ever use one agent at a time
- You want cloud-hosted agent orchestration (harnex is local-only)
- You need agents that aren't terminal-based

## What it looks like

Start agents, name them, send messages between them:

```bash
harnex run codex --id worker
harnex send --id worker --message "implement the auth module"
harnex send --id worker --message "now write tests" --wait-for-idle
harnex status
harnex stop --id worker
```

Messages queue automatically when an agent is busy and deliver
when it's ready. Agents see who sent each message. No polling,
no retrying, no glue scripts.

## Install

```bash
gem install harnex
```

Or from source:

```bash
git clone https://github.com/jikkujose/harnex.git
cd harnex && gem build harnex.gemspec && gem install harnex-*.gem
```

Needs Ruby 3.x. No other dependencies — stdlib only.

## Supported agents

Works today with **Claude Code** and **OpenAI Codex**. Any other
terminal CLI gets generic wrapping (you lose smart prompt detection
but everything else works). Adding a new agent is one small file.

## Going deeper

- [GUIDE.md](GUIDE.md) — practical getting-started for new users
- [TECHNICAL.md](TECHNICAL.md) — command reference, flags, HTTP
  API, and internals

## License

[MIT](LICENSE)
