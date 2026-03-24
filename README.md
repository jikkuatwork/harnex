# Harnex

If you use AI coding agents in the terminal and want a reliable way
to launch them, hand them one job, watch what they do, and stop them
cleanly, that's what harnex does.

It can relay messages between sessions, but the most dependable
workflow is simpler: run fresh Codex and Claude workers in tmux, send
each one a single task, inspect progress with `harnex pane`, and pass
file artifacts from step to step. Codex plans and implements. Claude
reviews.

```
  You
   │
   ├── harnex run codex  --id cx-plan-23 --tmux
   ├── harnex send --id cx-plan-23 --message "Write /tmp/plan-23.md"
   ├── harnex run codex  --id cx-impl-23 --tmux
   ├── harnex send --id cx-impl-23 --message "Read /tmp/plan-23.md"
   ├── harnex run claude --id cl-rev-23 --tmux
   └── harnex send --id cl-rev-23 --message "Review and write /tmp/review-23.md"
```

## When you'd want this

- You want a local supervisor harness for fresh agent instances
- You want Codex to plan or implement and Claude to review
- You want to inspect real screens and logs instead of trusting
  callback messages
- You want serial plan -> implement -> review -> fix workflows
  without juggling terminal tabs

## When you wouldn't

- You only ever use one agent at a time
- You want cloud-hosted agent orchestration (harnex is local-only)
- You need agents that aren't terminal-based

## What it looks like

Start a worker, send one task, watch it, stop it:

```bash
harnex run codex --id cx-impl-23 --tmux
harnex send --id cx-impl-23 --message "Read and execute /tmp/task-23.md" --wait-for-idle --timeout 600
harnex pane --id cx-impl-23 --lines 60
harnex stop --id cx-impl-23
```

Queueing and relay still exist when you need them, but the default
pattern is one task per fresh worker plus screen-based observation.

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

## Links

[![Hypercommit](https://img.shields.io/badge/Hypercommit-DB2475)](https://hypercommit.com/harnex)
