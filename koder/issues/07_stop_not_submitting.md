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
