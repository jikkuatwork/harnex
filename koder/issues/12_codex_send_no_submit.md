# Issue 12: State detection failures cause send/receive problems

Priority: P1
Status: open

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

Observed: Codex sent two relay messages to Claude session `hh`. Both were
queued (`delivered_total: 2`). When the user tried to type, the queued
messages got pasted into the input, corrupting the user's input.

## Root cause

State detection heuristics in both adapters fail to recognize prompt states
in certain screen configurations:

- **Codex adapter**: `input_state` requires screen text to contain
  `"OpenAI Codex"` or `"gpt-"` to activate Codex-specific detection. If the
  screen buffer doesn't include these strings (e.g. after scrolling or in
  `--no-alt-screen` mode), it falls back to generic detection which returns
  `"unknown"`.

- **Claude adapter**: vim mode detection was added in issue #09 but the base
  prompt detection may not cover all Claude Code UI states (e.g. when Claude
  is showing a tool approval prompt or other non-standard screens).

## Investigation needed

- Verify whether `\r` vs `\n` matters for Codex submit
- Check if the 75ms delay is sufficient for Codex's TUI rendering
- Investigate why `input_state` returns `"unknown"` for Codex at a prompt
  (the `--no-alt-screen` flag may affect screen text detection)
- Review Claude adapter detection for edge cases beyond vim mode
- Consider whether the inbox should refuse to deliver when state is `"unknown"`
  rather than treating it as potentially prompt-ready
- Test with `--verbose` to see exact delivery timing

## Reproduction

### Codex send failure

```bash
harnex run codex --tmux --description "test"
# Wait for Codex to reach prompt
harnex send --id <ID> --message "echo hello" --verbose
# Observe: text appears in Codex input but is not submitted
```

### Claude receive failure

```bash
# From a Codex session managed by harnex:
harnex send --id <claude-id> --message "result here"
# Message gets queued, then pastes into Claude input on next user interaction
```
