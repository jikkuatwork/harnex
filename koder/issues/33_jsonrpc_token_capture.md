---
status: open
priority: P2
created: 2026-05-06
tags: telemetry,dispatch,jsonrpc,observability,tokens
---

# Issue 33: JSON-RPC adapter doesn't capture token usage in DISPATCH telemetry

## Summary

For sessions run through the JSON-RPC `codex app-server` adapter (i.e.,
without `--legacy-pty`), `actual.input_tokens`, `actual.output_tokens`,
`actual.reasoning_tokens`, and `actual.cached_tokens` are all `null` in
the DISPATCH.jsonl row.

The PTY adapter populates these fields. Compare two rows from
`/home/glasscube/Projects/holmhq/holm/master/koder/DISPATCH.jsonl`:

```jsonl
# PTY adapter (0.5.0):
{"meta":{"id":"cx-cf-388","harness_version":"0.5.0",...},
 "actual":{"input_tokens":197819,"output_tokens":25018,"reasoning_tokens":12501,"cached_tokens":6408576,...}}

# JSON-RPC adapter (0.6.3, post-fix):
{"meta":{"id":"cx-s63-1","harness_version":"0.6.3",...},
 "actual":{"input_tokens":null,"output_tokens":null,"reasoning_tokens":null,"cached_tokens":null,
           "model":"gpt-5.5-mini","effort":"low",...}}
```

`model` and `effort` flow through fine (they come from `--meta`). The
token fields don't, presumably because the PTY adapter scrapes them
from terminal output and the JSON-RPC adapter would have to read them
from a different source.

## Why this matters

DISPATCH.jsonl is the cross-session cost ledger. Token counts are the
load-bearing field for cost analysis — without them:

- Per-dispatch cost (`tokens × model price`) can't be estimated.
- "Which model/effort tier is cheapest for tier-C work" can't be
  answered from telemetry.
- Holm's session rollup (proposed in holm `#272`) won't have token
  totals to surface in SESSION.jsonl.

Once 0.6.3 lands as the default adapter for new dispatches, every new
DISPATCH row will be missing token data — exactly the wrong direction
for observability.

## Where the data lives

Codex's JSON-RPC protocol surfaces token usage in
`item_completed` / `task_complete` events. The schema is in the
`generate-json-schema` output that proved load-bearing for #29. Each
`turn_completed` notification carries a `usage` object with input/output
token counts. The adapter just isn't reading and forwarding them.

Repro from `cx-s63-1` events (truncated):

```jsonl
{"seq":12,"id":"cx-s63-1","type":"task_complete","turnId":null}
```

Compare to what Codex actually emits (from `generate-json-schema`):
`task_complete` includes `usage: { input_tokens, output_tokens,
cached_tokens, reasoning_tokens }` per the `TaskCompleteParams` shape.

## What "fixed" looks like

1. In `Adapters::CodexAppServer`, listen for `task_complete` (or the
   per-turn `turn_completed`) notifications and extract the `usage`
   block.
2. On session end, write those token counts into the DISPATCH row's
   `actual.{input_tokens,output_tokens,reasoning_tokens,cached_tokens}`
   fields.
3. Add a contract-style assertion in tests (per #30's pattern) that
   the stub responses include realistic `usage` objects so the
   adapter's parsing path stays exercised.

## Acceptance

- A JSON-RPC dispatch's DISPATCH row has non-null
  `actual.input_tokens` and `actual.output_tokens`.
- A test in `codex_appserver_test.rb` (or sibling) exercises the
  `usage` parsing path with a Codex-shaped stub response.

## Related

- #29 (closed, fixed in 0.6.3) — same adapter, sibling schema-mismatch
  family.
- #30 (open, P1) — contract-test gate that should catch the future
  drift this fix introduces.
- #32 (open, P1) — DISPATCH row not written on early-boot fail. Once
  #32 is fixed, the row exists; this issue ensures the row is *useful*.
- holm #272 (open) — SESSION.jsonl rollup depends on these fields
  being populated.
