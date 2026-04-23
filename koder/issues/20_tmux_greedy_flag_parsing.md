---
id: 20
title: "--tmux greedily consumes next flag as window name"
status: open
priority: P1
created: 2026-04-23
---

# Issue 20: --tmux Greedily Consumes Next Flag as Window Name

## Problem

`--tmux [NAME]` has an optional argument, but the parser greedily consumes the
next token even when it's a known flag.

```bash
harnex run codex --tmux --name cx-p-322 --context "..."
```

Produces `"window":"--name"` — `--name` is eaten as the tmux window name
instead of being parsed as a separate flag.

## Root Cause

`tmux_name_arg?` in `lib/harnex/commands/run.rb:340-346`:

```ruby
def tmux_name_arg?(argv, index, cli_name)
  value = argv[index + 1]
  return false if value.nil? || value == "--" || wrapper_option_token?(value)
  return true if cli_name  # ← early return without validating next token
  cli_candidate_after?(argv, index + 2)
end
```

When `cli_name` is already set (`codex` parsed earlier), the method returns
`true` immediately without checking if the next token starts with `--` or is
in `KNOWN_FLAGS`. Any flag following `--tmux` gets swallowed as the window name.

## Impact

- Corrupted arg parsing feeds invalid arguments downstream
- Likely explains Codex registration failures — sessions never register within
  the timeout because args are mangled
- Claude sessions also affected but less visibly (Claude ignores unknown args)

## Workaround

Use `--id` instead of `--name` (`--id` is parsed before `--tmux`):

```bash
harnex run codex --tmux --id cx-p-322 --context "..."
# Works: "id":"cx-p-322", "window":"cx-p-322"
```

## Proposed Fix

Add a `--` prefix check before the `cli_name` early return:

```ruby
def tmux_name_arg?(argv, index, cli_name)
  value = argv[index + 1]
  return false if value.nil? || value == "--" || wrapper_option_token?(value)
  return false if value.start_with?("--")  # ← never consume flags
  return true if cli_name
  cli_candidate_after?(argv, index + 2)
end
```
