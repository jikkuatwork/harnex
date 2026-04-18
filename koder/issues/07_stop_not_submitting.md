---
id: 7
title: "`harnex stop` types /exit but doesn't submit it"
status: open
priority: P1
created: 2026-03-15
---

# Issue 7: `harnex stop` Types Exit Sequence But Doesn't Submit

## Problem

When calling `harnex stop --id <session>`, the `/exit` text is injected into the
agent's terminal but the Enter keypress either doesn't fire or arrives before the
text is fully rendered, leaving the agent with `/exit` typed in the input box but
not submitted.

Observed with Codex adapter during chain-implement v2 workflow in the Holm repo.
The API returns `{"ok":true,"signal":"exit_sequence_sent"}` suggesting it believes
delivery succeeded, but the tmux window shows `/exit` sitting unsubmitted.

## Reproduction

```bash
harnex run codex --id test --tmux cx-test
# wait for prompt
harnex send --id test --message "create a file called foo.txt with content hello"
# wait for completion
harnex stop --id test
# observe: /exit typed but not submitted in tmux window
```

## Expected

The agent should receive `/exit` + Enter and terminate cleanly.

## Likely Cause

The `inject_exit` method in the Codex adapter may be writing `/exit\n` as a
single write, but the terminal needs a delay between the text and the newline
(similar to the 75ms delay in `build_send_payload` for regular messages). Or
the submit sequence isn't being appended at all.

## Impact

Lingering Codex sessions after `harnex stop` during automated workflows. The
supervisor believes the session is stopped but it's still running. Currently
worked around by the user manually pressing Enter in the tmux window.

## Additional Pattern: Stream Disconnect → Zombie (2026-04-18)

During Holm Analysis 004, Codex sessions repeatedly hit OpenAI stream disconnects
(`"stream disconnected before completion: response.failed event received"`). After
a disconnect, Codex drops to its idle prompt. When `harnex stop` is called on
these sessions, the `/exit` sequence is sent but not processed — the session
persists as a zombie.

Observed: `cx-impl-262b` and `cx-impl-263` both survived `harnex stop` and were
still showing as `session` state 40+ minutes later. Required a second manual
`harnex stop` to clean up.

This is the same root cause (exit sequence not submitted) but a distinct trigger:
the disconnect leaves Codex in a state where it may not be accepting input until
the user interacts. `harnex send --message` also failed to get through to these
sessions (timed out after 15s).

Suggested fix directions:
- After sending `/exit`, poll `harnex pane` or check PID liveness for N seconds
- If process is still alive, escalate to SIGTERM → SIGKILL
- Consider a `--force` flag that skips the exit sequence and kills the process
