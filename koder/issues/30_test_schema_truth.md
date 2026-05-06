---
status: open
priority: P1
created: 2026-05-06
tags: tests,appserver,jsonrpc,contract,quality
---

# Issue 30: Test stubs validate harnex against itself, not against Codex's actual schema

## Summary

Issue #29 was filed as fixed in `harnex 0.6.2` but the patch did not
actually work against real Codex CLI. 100% session-disconnect rate at
boot under JSON-RPC mode (4/4 stress sessions on 2026-05-06, plus the
user's own `cx-impl-018` first-attempt earlier the same day).

Root cause: three schema-mismatch bugs in `Adapters::CodexAppServer`
were shipped because the test stubs in `codex_appserver_lifecycle_test.rb`
and `session_jsonrpc_test.rb` respond with field names harnex *expected*
(`{"threadId" => "thr-1"}`, `input.content[0].text`) instead of Codex's
actual JSON-RPC response shape (`{"thread": {"id": "..."}}`,
`input[0].text`). Tests validated harnex against its own assumptions
and passed cleanly while production was 100% broken.

`harnex 0.6.3` ships the production fix and updates the two assertion
lines that probed the wrong shape. The structural fix — having the test
stubs reflect Codex's actual schema — is this issue.

## Why this matters

Future Codex protocol revs (or our own future patches) will ship the
same way: clean tests, broken production. The defect is structural in
the test design, not in any individual assertion.

## What "fixed" looks like

1. **Test stubs reflect Codex's actual schema.** The simplest path is
   to use minimal-but-real shapes:

   ```ruby
   # thread/start response
   {
     "thread" => {
       "id" => "thr-1",
       "cliVersion" => "0.128.0",
       "createdAt" => Time.now.to_i,
       "updatedAt" => Time.now.to_i,
       "cwd" => "/tmp",
       "ephemeral" => true,
       "modelProvider" => "openai",
       "preview" => "",
       "source" => "appServer",
       "status" => { "type" => "idle" },
       "turns" => []
     },
     "approvalPolicy" => "untrusted",
     "approvalsReviewer" => "user",
     "cwd" => "/tmp",
     "model" => "gpt-5",
     "modelProvider" => "openai",
     "sandbox" => { "type" => "readOnly" }
   }
   ```

   Same treatment for `thread/started` notification (params has
   `thread:` not `threadId:`).

2. **Outgoing-payload assertions check the actual shape Codex expects.**
   Existing tests assert that `params.input[0].text` carries the prompt;
   that's the correct path under `TurnStartParams`. Add an assertion
   that `params.input` is an `Array`, not a `Hash`.

3. **Contract-test gate.** Generate Codex's schema at test time:

   ```ruby
   def codex_schema
     @codex_schema ||= begin
       Dir.mktmpdir do |dir|
         system("codex", "app-server", "generate-json-schema", "--out", dir, exception: true)
         {
           thread_start_response: JSON.parse(File.read("#{dir}/v2/ThreadStartResponse.json")),
           turn_start_params: JSON.parse(File.read("#{dir}/v2/TurnStartParams.json"))
         }
       end
     end
   end
   ```

   Validate harnex's outgoing `turn/start` request body against
   `TurnStartParams.json` using a JSON-Schema validator (e.g.
   `json-schema` gem). If Codex changes its schema, this test fails;
   harnex doesn't ship a broken adapter.

4. **Test fixture file** with a captured real `thread/start` response
   from `codex app-server` (committed to `test/fixtures/`). Keeps
   tests fast (no subprocess) but grounds them in reality.

## Acceptance test

Two scenarios that must pass without `--legacy-pty`:

1. `harnex run codex --tmux X --id X --context "echo OK > /tmp/X-done.txt; exit"`
   → done marker appears, `task_complete` fires, telemetry record lands.
2. Mid-session `harnex send --id X --message "hello"` lands as a new
   `turn/start` request body whose `params` validate against the
   generated `TurnStartParams.json`.

## Out of scope

- Further Codex schema coverage (e.g. `thread/resume`, error notifications).
  Those can come later; this issue focuses on `thread/start` + `turn/start`,
  the two paths that actually broke #29 twice.
- Removing `--legacy-pty`. Still scheduled for 0.7.0; this issue is
  prerequisite work.

## References

- harnex 0.6.3 fix commit: `eb9fccb fix(adapters): JSON-RPC --context schema-mismatch repairs (#29)`
- harnex 0.6.3 release commit: `036cf13 chore(release): prepare harnex 0.6.3`
- holm analysis: `koder/analysis/260_harnex_062_capability_review/INDEX.md`
  (cross-repo bug-find that surfaced this)
- evidence (gitignored): `~/.local/state/harnex/events/*--cx-stress-{1,2,3,4}.jsonl`
- spike script: `/tmp/codex-spike.rb`
