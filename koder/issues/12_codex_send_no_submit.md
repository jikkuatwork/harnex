---
status: resolved
---

# Issue 12: State detection failures cause send/receive problems

Priority: P1
Status: **fixed**

## Problem

State detection (`input_state`) returns `"unknown"` for both Codex and Claude
sessions when the agent is actually at a prompt. This causes two distinct
failures in message delivery:

### Failure 1: Outbound send doesn't submit (Codex)

When sending to a Codex session, text is injected into the input box but the
Enter keystroke doesn't take effect. The user has to manually press Enter.

- `harnex send --id <codex> --message "<task>"` returns `"status":"delivered"`
  with `"newline":false`
- Codex session's `input_state` is `{"state":"unknown","input_ready":null}`
- The two-step inject sequence (text + `\r` with 75ms delay) executes but
  Codex doesn't process the submit

### Failure 2: Inbound messages paste at wrong time (Claude)

When a peer sends a message back to a Claude session (e.g. Codex sending
results via `harnex send --id hh`), the message gets queued because Claude's
state shows as `"unknown"`. When the user next interacts with the terminal,
the inbox sees apparent prompt-readiness and dumps the queued message text
into the input box — mixed in with whatever the user was typing.

## Root cause

The OSC (Operating System Command) escape sequence stripping regex in
`Adapters::Base#normalized_screen_text` used a **greedy** quantifier:

```ruby
text.gsub(/\e\][^\a]*(?:\a|\e\\)/, "")
```

The `[^\a]*` (greedy) matches `\e` characters, so when the screen buffer
contains multiple OSC sequences like `\e]10;?\e\\\e]11;?\e\\`, the regex
consumes everything from the first `\e]` to the **last** `\e\\` in the buffer
— eating all printable content in between. This left the normalized text
empty, causing all adapter `input_state` calls to fall through to `"unknown"`.

Codex TUI uses OSC queries (`\e]10;?` and `\e]11;?`) during initialization,
which reliably triggered this bug. Claude was also affected (the greedy match
stripped ~9MB of a 16MB buffer) but happened to still detect prompts because
the prompt markers appeared after the last OSC terminator.

## Fix

One-character change — make the OSC quantifier non-greedy:

```ruby
text.gsub(/\e\][^\a]*?(?:\a|\e\\)/, "")
```

This correctly terminates each OSC sequence at its own `\e\\` terminator
rather than consuming through to the last one in the buffer.

Regression tests added in `base_test.rb` and `codex_test.rb`.

## Verified

Dogfooded live: launched Codex via `harnex run codex --tmux`, confirmed
`input_state` returned `prompt` (was `unknown`), successfully sent a task
via `harnex send`, and received a relay response back — full round-trip
agent-to-agent messaging working.
