# Codex JSON Schema fixtures

These files are a pinned subset of the schemas emitted by

    codex app-server generate-json-schema --out <dir>

They are the source of truth for harnex's JSON-RPC contract tests
(plan 29, issue #30). Every JSON-RPC request, response, or
notification harnex sends, parses, or auto-approves is validated
against the matching schema here.

## Pinned version

    codex-cli 0.144.1

The `Phase 6` drift gate (`test/harnex/contract/schema_freshness_test.rb`,
landing in commit 6 of plan 29) re-runs the generator at test time and
fails if any file in this directory diverges from a fresh capture. To
refresh after an intentional Codex bump:

    codex app-server generate-json-schema --out /tmp/codex-schema
    cd test/fixtures/codex_schema
    find . -name '*.json' | while read f; do cp "/tmp/codex-schema/$f" "$f"; done

That overwrites only files already tracked here — new Codex schemas
are not pulled in implicitly. Then re-run the suite. If the change
requires harnex changes, file an issue and patch the adapter; do not
patch the fixture without a matching code or test change.

## Files included

v2 protocol (the default JSON-RPC transport `harnex run codex` uses):

- `v2/ThreadStartParams.json`, `v2/ThreadStartResponse.json` — the
  request `Adapters::CodexAppServer#ensure_thread!` issues and the
  response shape `extract_thread_id` parses.
- `v2/TurnStartParams.json`, `v2/TurnStartResponse.json` — the request
  `Session#dispatch` issues for `--context` and `harnex send`, and the
  response shape that yields the turn id.
- `v2/TurnStartedNotification.json`,
  `v2/TurnCompletedNotification.json` — the notifications that drive
  busy/prompt state plus `task_complete` / `task_failed` work events.
- `v2/ThreadTokenUsageUpdatedNotification.json` — the cumulative
  `tokenUsage.total` snapshot that flows into the DISPATCH row's
  `actual.{input,output,reasoning,cached}_tokens` fields.
- `v2/ErrorNotification.json` — server-side error notifications fed
  into disconnect classification.

Server-to-client approval requests (auto-approved by the JSON-RPC
mediator that landed in 0.6.4):

- `ApplyPatchApprovalParams.json`, `ApplyPatchApprovalResponse.json`
- `ExecCommandApprovalParams.json`, `ExecCommandApprovalResponse.json`
- `CommandExecutionRequestApprovalParams.json`,
  `CommandExecutionRequestApprovalResponse.json`
- `FileChangeRequestApprovalParams.json`,
  `FileChangeRequestApprovalResponse.json`

## Files deliberately excluded

**Master bundles**
(`codex_app_server_protocol.schemas.json`,
`codex_app_server_protocol.v2.schemas.json`).

Excluded for three reasons:

1. The bundles concatenate every Codex schema. Phase 6's drift rule
   is "the schemas we've adopted changed shape" — but with bundles in
   the fixture, any new MCP type, FuzzyFileSearch update, or
   ChatGPT-auth refresh would trip the drift gate even when nothing
   harnex touches changed.
2. They add no validator value. Each individual schema file is
   self-contained — every `$ref` resolves to a local
   `#/definitions/X` within the same file. Cross-file resolution is
   never needed.
3. They are not byte-stable across runs. Two consecutive
   `generate-json-schema` invocations on the same Codex version
   produce different master-bundle bytes (verified at capture time on
   0.128.0 and refreshed on 0.130.0). The individual schemas above are
   byte-stable.

**Schemas harnex doesn't touch**
(`FuzzyFileSearch*`, `McpServerElicitation*`, `ChatgptAuthTokensRefresh*`,
`DynamicToolCall*`, `PermissionsRequestApproval*`, the JSON-RPC
envelope schemas, etc., and most of the `v1`/`v2` directories).

Adding them later when harnex grows new request/response handling is
cheap. Including them today would inflate the fixture footprint
without buying contract coverage for code that doesn't exist yet.

## Footprint

16 schema files, ~256 KB total.
