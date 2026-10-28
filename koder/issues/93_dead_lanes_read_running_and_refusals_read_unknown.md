---
status: resolved
priority: P1
created: 2026-10-28
updated: 2026-10-28
tags: lanes, json, outcome, provider-errors, unattended, watch
type: bug
related: 86, 82
---

# Issue 93 — Dead lanes read `running`, and provider refusals read "Unknown error"

## What happened (Holm Queue 174, 2026-10-28)

An unattended overnight queue lost 8.5 hours. Two lanes (`q174-k1-nesting`, sol;
`q174-a1-isolation`, astra) failed every 13 s – 4 min from 01:52 local, and nothing
noticed until the owner returned at 10:28.

1. **`harnex lanes --json` reported `"state": "running"` for lanes whose worker had
   settled** (`"live": false`, `"outcome": "failed"`, `last_error` set). The table
   shows "finished, uncollected", but the JSON `state` stays `running` until someone
   runs `harnex result`. The orchestrator's poller trusted `state` and never saw the
   failures.
2. **Every failure was a provider refusal, shown as "Unknown error (no error details
   in response)".** Foundry's ledger holds the real reason: the upstream stream sent
   `response.failed` with no `response.error`, then a separate
   `{"type":"error","code":"cyber_policy","message":"This content was flagged for
   possible cybersecurity risk…"}`. Pi stops at the first event, so harnex records
   `outcome_class: task_failed` with the generic text. The orchestrator assumed
   "transient" and retried refused content eight times.

## Wanted

- **Honest lane state.** A lane whose worker has settled reports its settled
  state in `lanes --json` (`done` / `failed`), never `running`, whether or not it
  has been collected. Keep collection as its own field (e.g. `"collected": false`).
  The table, `lanes --json`, MCP `lanes` and `watch` agree.
- **Refusals are their own outcome.** A Pi turn that ends in a provider refusal
  (`cyber_policy`, content filter / content policy, "flagged for possible
  cybersecurity risk") settles with `outcome_class: "policy_refusal"`. The footer
  says the provider refused this content, so a retry needs a rephrased brief or
  another route, and never suggests "Continue the same task".
- **Unexplained provider errors say so.** "Unknown error (no error details in
  response)" settles as `outcome_class: "provider_error_unexplained"`, with a
  footer hint to read the provider/gateway logs before retrying, not the usual
  generic "Continue the same task" suggestion.
- `watch --owner` events carry the new outcome classes unchanged.

## Not in scope

Automatic retry (#86 slice 3) and any provider-specific API call from harnex.

## Resolution

- `lanes --json` projects settled `done`/`failed` independently of
  `collected`, without consuming results. The table (also what MCP `lanes`
  returns, since it carries live worker activity) keeps its wording, which
  already reads "finished, uncollected". Evidence is fenced to the
  launch/follow-up.
- Pi refusal errors settle as `policy_refusal`; the exact no-details error
  settles as `provider_error_unexplained`. Footers require rephrasing/another
  route or provider/gateway log inspection, respectively. Owner-watch events
  preserve both classes; outcome vocabulary and default failure budgets include
  them. Capacity behavior is unchanged.
- Test-first regressions failed on the original behavior (no missing symbols).
  Final regressions: 14 tests, 177 assertions; full AGENTS/CLAUDE suite:
  855 tests, 4,634 assertions, 0 failures/errors, 1 opt-in Pi integration skip.
  No live upstream-provider test, automatic retry, version bump or release.
