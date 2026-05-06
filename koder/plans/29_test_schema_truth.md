---
status: draft
issue: 30
created: 2026-05-07
---

# Plan 29 — Test schema truth + contract gate (#30)

## Goal

Make harnex's JSON-RPC tests fail when our outgoing payloads, or our
parsing of incoming Codex responses, drift from Codex's actual schema.

Today the stubs validate harnex against harnex's own assumptions, and
the result was: 0.6.1 → 0.6.2 → 0.6.3 shipped three schema-mismatch
bugs against 100% green tests, and the last 24h burned six issues
(#29 → #34) tracing back to this same gap. Tests need to use Codex's
schema as the source of truth, not harnex's.

Codex CLI version pinned at fixture-capture time: **0.128.0**.

Plan ships in six commits, each green at HEAD before moving on.

## Phase 1 — Schema fixture (commit 1)

Capture `codex app-server generate-json-schema --out` and check the
relevant subset into `test/fixtures/codex_schema/`. Files:

- `codex_app_server_protocol.v2.schemas.json` — master v2 bundle
- `codex_app_server_protocol.schemas.json` — master v1 bundle
- `v2/ThreadStartParams.json`, `v2/ThreadStartResponse.json`
- `v2/TurnStartParams.json`, `v2/TurnStartResponse.json`
- `v2/TurnStartedNotification.json`, `v2/TurnCompletedNotification.json`
- `v2/ErrorNotification.json`
- `ApplyPatchApprovalParams.json`, `ApplyPatchApprovalResponse.json`
- `ExecCommandApprovalParams.json`, `ExecCommandApprovalResponse.json`
- `CommandExecutionRequestApprovalParams.json`, `CommandExecutionRequestApprovalResponse.json`
- `FileChangeRequestApprovalParams.json`, `FileChangeRequestApprovalResponse.json`
- `README.md` — capture provenance + refresh command

These are exactly the request/response/notification shapes harnex
sends, parses, or auto-approves. Other Codex schemas (FuzzyFileSearch,
MCP elicitation, ChatGPT auth-token refresh, etc.) stay out — adding
them later is cheap, but they're not load-bearing today and would just
inflate the fixture footprint.

Estimated footprint: ~150 KB of small JSON files.

## Phase 2 — Stdlib JSON Schema validator (commit 2)

Project policy is stdlib-only — no gems, including dev-only. Vendor a
focused Draft-7 subset validator at `test/support/json_schema_validator.rb`
(~250 LOC). Supported keywords:

- `type` (string | number | integer | boolean | array | object | null
  | array-of-types for unions like `["string","null"]`)
- `required`
- `enum`
- `const`
- `properties` + `additionalProperties: false | true | <schema>`
- `items` (homogeneous arrays)
- `oneOf`, `anyOf`, `allOf`
- `$ref` to `#/definitions/X` (local-only — no remote refs)

Returns `[]` on valid, or an array of `{path: "/foo/bar", message: "..."}`
errors on invalid.

Self-tests at `test/support/json_schema_validator_test.rb` — positive
and negative case for each keyword, plus a couple end-to-end checks
against real Codex schema files.

This is the smallest investment that lets us adopt Codex's schema as
test ground truth without violating "stdlib only".

## Phase 3 — Outgoing payload contract tests (commit 3)

New test file: `test/harnex/adapters/codex_appserver_contract_test.rb`.

Mechanism: feed `Adapters::CodexAppServer` an `IO.pipe`-based fake
server, capture every JSON line `JsonRpcClient#write_line` emits,
parse each one, and validate `params` (for outgoing requests) or the
response body (for our auto-approval `result`s) against the matching
schema fixture.

Cases:

1. `initialize` request — assert `clientInfo` and `capabilities`
   shape (no schema file for `initialize` — encode contract inline).
2. `thread/start` request — validates against `ThreadStartParams`.
3. `turn/start` request with prompt only.
4. `turn/start` request with `model: "gpt-5.5"` and `effort: "high"`.
5. `turn/start` request from inbox-delivered `harnex send` (i.e.
   exercise the end-to-end inject path, not just the adapter).
6. `turn/interrupt` request — encode contract inline (params is
   `{threadId, turnId}`).
7. Auto-approval response bodies for the four request methods, each
   validated against the corresponding `*ApprovalResponse` schema.

Case 7 is the one expected to **fail** initially: the
`item/commandExecution/requestApproval` response body
`{decision: "approved"}` does not validate against
`CommandExecutionApprovalDecision`, whose enum is
`accept | acceptForSession | decline | cancel | ...`. Mark this as
the bug Phase 5 fixes — see below.

## Phase 4 — Realistic incoming-response stubs (commit 4)

Replace stub responses in `codex_appserver_lifecycle_test.rb` and
`session_jsonrpc_test.rb` with shapes that match Codex's real schema.

New helper: `test/support/codex_response_fixtures.rb` exposes builder
functions, e.g.:

- `Fixtures::Codex.thread_start_response(id: "thr-1")` →
  full `{thread: {id, cliVersion, ...}, approvalPolicy, model, ...}`
- `Fixtures::Codex.thread_started_notification(id: ...)` —
  notification params has `thread:` not `threadId:`
- `Fixtures::Codex.turn_start_response(id: "trn-1")`
- `Fixtures::Codex.turn_started_notification(...)`,
  `Fixtures::Codex.turn_completed_notification(...)`
- `Fixtures::Codex.item_completed_agent_message(text:)`
- `Fixtures::Codex.item_completed_tool_call(name:, ...)`

Every builder output is itself validated against its schema in a
self-test (cheap insurance — if the builders drift, that's caught at
the source, not in twenty downstream tests).

Then rewrite the two existing test files:

- `codex_appserver_lifecycle_test.rb` — replace inline
  `{"threadId" => "thr-1"}` stubs with `Fixtures::Codex.thread_start_response(id: "thr-1")`.
- `session_jsonrpc_test.rb` — same treatment, plus the
  `thread/started` notifications that currently pass
  `{"threadId" => "thr-a"}` — switch to schema-shaped notifications
  with `params.thread.id`. Update `extract_thread_id`'s call sites
  accordingly.
- Add an extraction regression test: feed
  `Fixtures::Codex.thread_start_response` into
  `Adapters::CodexAppServer#extract_thread_id` (via `send(:...)`) and
  assert it returns the right id without exercising the legacy
  fallback path.

## Phase 5 — Adapter fixes surfaced by the contract tests (commit 5)

Discoveries made by Phases 3–4 that need to land before the freeze lifts:

1. **`APPROVAL_RESPONSES["item/commandExecution/requestApproval"]`**:
   change from `{decision: "approved"}` to `{decision: "accept"}`.
   `CommandExecutionApprovalDecision` does not include `"approved"`.
   This was a copy-paste from the `ReviewDecision` shape used by
   `applyPatchApproval` / `execCommandApproval` and almost certainly
   means harnex's auto-approver has been sending a value Codex
   rejects on every default-sandbox `commandExecution` request since
   the mediator landed in 0.6.4. Verify production impact before
   claiming the fix is "needed in prod"; ship it regardless because
   the schema is unambiguous.

2. **`extract_thread_id` fallbacks** (`payload["threadId"] ||
   payload["thread_id"]`): drop. These were the original #29 bug —
   they made the wrong shape silently accepted. With the contract
   gate enforced, fallbacks become anti-defensive: they hide future
   Codex schema breaks instead of surfacing them. Same for
   `dispatch`'s `result["turn_id"] || result["id"]` chain.

3. Reconsider whether `dispatch` should require `result["turnId"]`
   to be a string and raise loudly otherwise; today it returns nil
   and the session moves on with `@current_turn_id = nil`.

(Phase 5 may grow as Phases 3–4 surface more findings; current count
is two confirmed plus one cleanup.)

## Phase 6 — Drift gate (commit 6)

New test: `test/harnex/contract/schema_freshness_test.rb`.

Behavior:

- If `codex` CLI is not on PATH, skip with a clear message.
- If `HARNEX_SKIP_SCHEMA_DRIFT=1`, skip.
- Otherwise: run `codex app-server generate-json-schema --out <tmpdir>`
  and compare each file we ship in `test/fixtures/codex_schema/` to
  the freshly-generated equivalent (byte-equal after `JSON.parse`
  round-trip to normalize key order).
- On drift, fail with an actionable message:

  ```
  Schema drift detected in <relative_path>.

  Codex's schema for this type has changed since the fixture was
  captured. Refresh the fixture:

      codex app-server generate-json-schema --out /tmp/codex-schema
      cp /tmp/codex-schema/<file> test/fixtures/codex_schema/<file>

  Then re-run the suite. If the change requires harnex changes, file
  an issue and patch the adapter.
  ```

We compare *only the files we ship*. Codex adding new schemas (e.g.
new MCP types) is not drift in our contract — drift is the schemas
we've adopted changing shape.

The drift gate runs in the main suite. Combined with Phases 3–4,
this means schema drift cannot ship silently:

- If Codex changes a type harnex parses → contract tests fail (real
  adapter bug surfaced at the harnex side).
- If Codex changes a type harnex generates → contract tests fail
  (our outgoing payload no longer validates).
- If Codex bumps a schema we shipped a fixture for → drift gate
  fails (refresh the fixture intentionally).

## Acceptance

- Full suite green at HEAD after each phase commit.
- Contract tests catch a deliberately-introduced schema bug (sanity
  check: revert one line of #29's fix, see Phase 3 fail).
- `codex_appserver_lifecycle_test.rb` and `session_jsonrpc_test.rb`
  use the schema-shaped response builders, not literals harnex made up.
- `item/commandExecution/requestApproval` decision corrected to
  `"accept"`.
- `extract_thread_id` and `dispatch` fallbacks removed.
- Drift gate triggers correctly when fixtures are stale; skips
  cleanly when codex is not installed.

## Out of scope

- Coverage for Codex schemas harnex doesn't touch (FuzzyFileSearch,
  MCP elicitation, ChatGPT auth refresh, dynamic tool calls, etc.).
- Splitting contract tests into a CI-only suite — the stdlib
  validator is fast enough to keep them in the main suite.
- Adapter abstraction work (#06).
- `--legacy-pty` removal (long-term fallback per the freeze close).
- Schema fixture for `thread/resume` — harnex doesn't currently call
  it; add when #15's resume path lands.

## Notes for the executor

Each commit message should reference issue #30 in the form
`fix(tests): ... (#30)` or `feat(tests): ... (#30)` and reference
this plan. Commit 1 may also have to include a `.gitignore` entry if
the captured fixture's master bundle has a generated timestamp field
that breaks idempotency — verify on first capture.

If Phase 5 finding #1 (the `decision: "accept"` vs `"approved"` bug)
turns out to have a live production impact, file a backlog issue
(or fold into #30's closing notes) so the release notes call it out
explicitly. The user runs JSON-RPC dispatches with the default
codex sandbox, so this is on the hot path.
