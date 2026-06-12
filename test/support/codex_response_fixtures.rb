require "json"

# Schema-shaped fixtures for Codex `app-server` JSON-RPC responses and
# notifications. Used by adapter and session tests so stubs reflect what
# Codex actually emits, not harnex's earlier (incorrect) assumptions.
#
# Each builder returns the literal field names the captured JSON Schema
# fixtures (`test/fixtures/codex_schema/`) require — only required keys
# plus a small set of common optionals. Builders are themselves
# validated against the matching schema in
# `test/support/codex_response_fixtures_test.rb`, so drift gets caught
# at the source rather than in twenty downstream tests.
#
# Fixtures pinned to codex-cli 0.139.0 (see fixture README for refresh).
module Fixtures
  module Codex
    module_function

    # ----- Thread (nested in ThreadStartResponse, thread/started) -----

    def thread(
      id:,
      cli_version: "0.128.0",
      cwd: "/tmp",
      model_provider: "openai",
      preview: "",
      session_id: "sess-1",
      created_at: 1_700_000_000,
      updated_at: 1_700_000_000
    )
      {
        "id" => id,
        "cliVersion" => cli_version,
        "createdAt" => created_at,
        "cwd" => cwd,
        "ephemeral" => false,
        "modelProvider" => model_provider,
        "preview" => preview,
        "sessionId" => session_id,
        "source" => "appServer",
        "status" => { "type" => "idle" },
        "turns" => [],
        "updatedAt" => updated_at
      }
    end

    # ----- ThreadStartResponse -----

    def thread_start_response(
      id:,
      model: "gpt-5.5",
      model_provider: "openai",
      cwd: "/tmp"
    )
      {
        "approvalPolicy" => "never",
        "approvalsReviewer" => "user",
        "cwd" => cwd,
        "model" => model,
        "modelProvider" => model_provider,
        "sandbox" => { "type" => "readOnly" },
        "thread" => thread(id: id, model_provider: model_provider, cwd: cwd)
      }
    end

    # No `ThreadStartedNotification.json` fixture exists — plan 29 Phase 1
    # captured only the schemas harnex parses today, and harnex now reads
    # `thread.id` from the `thread/start` response itself. Shape here is by
    # analogy with the nested Thread object in ThreadStartResponse.
    def thread_started_notification(thread_id:, **opts)
      { "thread" => thread(id: thread_id, **opts) }
    end

    # ----- Turn (nested in TurnStartResponse, turn/started, turn/completed) -----

    def turn(id:, status: "inProgress", items: [])
      {
        "id" => id,
        "items" => items,
        "status" => status
      }
    end

    def turn_start_response(id:, status: "inProgress")
      { "turn" => turn(id: id, status: status) }
    end

    def turn_started_notification(thread_id:, turn_id:, status: "inProgress")
      {
        "threadId" => thread_id,
        "turn" => turn(id: turn_id, status: status)
      }
    end

    def turn_completed_notification(thread_id:, turn_id:, status: "completed", items: [])
      {
        "threadId" => thread_id,
        "turn" => turn(id: turn_id, status: status, items: items)
      }
    end

    # ----- ThreadItem variants (used inside item/completed) -----

    def agent_message_item(text:, id: "msg-1", phase: nil)
      item = {
        "id" => id,
        "text" => text,
        "type" => "agentMessage"
      }
      item["phase"] = phase if phase
      item
    end

    def item_completed_agent_message(text:, id: "msg-1", phase: nil)
      { "item" => agent_message_item(text: text, id: id, phase: phase) }
    end

    def mcp_tool_call_item(
      tool:,
      server: "shell",
      arguments: {},
      status: "completed",
      id: "tool-1"
    )
      {
        "id" => id,
        "type" => "mcpToolCall",
        "tool" => tool,
        "server" => server,
        "arguments" => arguments,
        "status" => status
      }
    end

    def item_completed_tool_call(tool:, **opts)
      { "item" => mcp_tool_call_item(tool: tool, **opts) }
    end

    # ----- ThreadTokenUsage / ThreadTokenUsageUpdatedNotification -----

    def token_usage_breakdown(
      input_tokens: 0,
      output_tokens: 0,
      cached_input_tokens: 0,
      reasoning_output_tokens: 0,
      total_tokens: nil
    )
      {
        "cachedInputTokens" => cached_input_tokens,
        "inputTokens" => input_tokens,
        "outputTokens" => output_tokens,
        "reasoningOutputTokens" => reasoning_output_tokens,
        "totalTokens" => total_tokens || (input_tokens + output_tokens)
      }
    end

    def thread_token_usage(last: nil, total: nil, model_context_window: nil)
      payload = {
        "last" => last || token_usage_breakdown,
        "total" => total || token_usage_breakdown
      }
      payload["modelContextWindow"] = model_context_window if model_context_window
      payload
    end

    def thread_token_usage_updated_notification(thread_id:, turn_id:, token_usage: nil)
      {
        "threadId" => thread_id,
        "turnId" => turn_id,
        "tokenUsage" => token_usage || thread_token_usage
      }
    end
  end
end
