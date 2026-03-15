# Plan 06: Claude Adapter Vim Mode Detection

Layer: A (multi-agent reliability)
Issue: #09
Date: 2026-03-15

## ONE THING

Recognize Claude Code's vim/normal mode as a sendable prompt state.

## Problem

Claude Code has a vim-style modal input. When the user presses Escape,
the prompt switches from insert mode (`--INSERT--` or `>` prefix) to
normal mode showing a `NORMAL` indicator. The current `input_state`
detection doesn't match this, so the session appears as `unknown` —
messages queue indefinitely waiting for a prompt transition that won't
happen until the user manually switches back to insert mode.

## Current detection in `claude.rb`

```ruby
elsif compact.include?("--INSERT--") || compact.include?("bypasspermissionson")
  { state: "prompt", input_ready: true }
elsif lines.any? { |line| prompt_line?(line) }
  { state: "prompt", input_ready: true }
else
  super  # → { state: "unknown", input_ready: nil }
end
```

The `--INSERT--` check handles insert mode. Normal mode falls through
to `unknown`.

## Fix

Add a detection branch for vim normal mode in `Claude#input_state`.

**`lib/harnex/adapters/claude.rb`** — add before the `else super` branch:

```ruby
elsif compact.include?("NORMAL") || compact.include?("--NORMAL--")
  {
    state: "vim-normal",
    input_ready: true
  }
```

Report it as `input_ready: true` because the session can still accept
injected text — PTY writes go through regardless of vim mode. The
adapter doesn't need to switch modes; the injected text appears in the
input buffer and submit works.

State is `"vim-normal"` rather than `"prompt"` so callers can
distinguish if needed, but `input_ready: true` means `wait_for_sendable`
and the inbox will treat it as deliverable.

### Structural changes

**`lib/harnex/adapters/claude.rb`** — one new `elsif` branch in
`input_state` (2 lines of condition, 4 lines of return hash).

### Tests

- Add test: screen text containing `NORMAL` returns
  `{ state: "vim-normal", input_ready: true }`
- Add test: screen text containing `--NORMAL--` returns same
- Existing `--INSERT--` tests still pass

## Acceptance criteria

- [ ] Claude adapter detects vim normal mode as sendable
- [ ] Messages deliver to Claude sessions in vim mode
- [ ] Existing insert-mode and prompt detection unchanged
- [ ] Tests pass

## Deferral list

- Detecting visual mode, command-line mode, or other vim states
- Auto-switching to insert mode before injection
- Other Claude UI states (e.g., search mode, compact mode)
