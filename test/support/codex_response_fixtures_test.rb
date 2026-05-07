require_relative "../test_helper"
require_relative "codex_response_fixtures"
require_relative "json_schema_validator"
require "json"

# Self-tests for `Fixtures::Codex` builders. Every builder output is
# validated against the matching schema fixture so drift is caught at
# the source — if a builder stops matching the schema, this file fails
# rather than every downstream adapter/session test.
class CodexResponseFixturesTest < Minitest::Test
  Validator = JsonSchemaValidator
  SCHEMA_DIR = File.expand_path("../fixtures/codex_schema", __dir__)

  def load_schema(rel_path)
    JSON.parse(File.read(File.join(SCHEMA_DIR, rel_path)))
  end

  def assert_valid(schema, instance, label, root_schema: nil)
    errors = Validator.validate(schema, instance, root_schema: root_schema)
    assert_empty errors, "#{label} failed schema validation: #{errors.inspect}"
  end

  # ----- ThreadStartResponse -----

  def test_thread_start_response_validates_against_schema
    response = Fixtures::Codex.thread_start_response(id: "thr-1")
    assert_valid(load_schema("v2/ThreadStartResponse.json"), response,
                 "thread_start_response")
  end

  def test_thread_start_response_with_custom_model
    response = Fixtures::Codex.thread_start_response(
      id: "thr-2", model: "gpt-5", model_provider: "openai"
    )
    assert_valid(load_schema("v2/ThreadStartResponse.json"), response,
                 "thread_start_response (custom model)")
    assert_equal "gpt-5", response["model"]
    assert_equal "thr-2", response.dig("thread", "id")
  end

  # ----- TurnStartResponse -----

  def test_turn_start_response_validates_against_schema
    response = Fixtures::Codex.turn_start_response(id: "trn-1")
    assert_valid(load_schema("v2/TurnStartResponse.json"), response,
                 "turn_start_response")
    assert_equal "trn-1", response.dig("turn", "id")
  end

  # ----- TurnStartedNotification -----

  def test_turn_started_notification_validates_against_schema
    notif = Fixtures::Codex.turn_started_notification(thread_id: "thr-1", turn_id: "trn-1")
    assert_valid(load_schema("v2/TurnStartedNotification.json"), notif,
                 "turn_started_notification")
    assert_equal "thr-1", notif["threadId"]
    assert_equal "trn-1", notif.dig("turn", "id")
  end

  # ----- TurnCompletedNotification -----

  def test_turn_completed_notification_validates_against_schema
    notif = Fixtures::Codex.turn_completed_notification(thread_id: "thr-1", turn_id: "trn-1")
    assert_valid(load_schema("v2/TurnCompletedNotification.json"), notif,
                 "turn_completed_notification")
    assert_equal "completed", notif.dig("turn", "status")
  end

  def test_turn_completed_notification_supports_other_statuses
    notif = Fixtures::Codex.turn_completed_notification(
      thread_id: "thr-1", turn_id: "trn-1", status: "interrupted"
    )
    assert_valid(load_schema("v2/TurnCompletedNotification.json"), notif,
                 "turn_completed_notification (interrupted)")
    assert_equal "interrupted", notif.dig("turn", "status")
  end

  # ----- ThreadItem variants -----
  # No standalone ThreadItem schema file — validate via the
  # `definitions.ThreadItem` block embedded in TurnStartedNotification.json
  # (it's the same Rust type, used wherever a Turn carries items).

  def threaditem_schema_with_root
    schema = load_schema("v2/TurnStartedNotification.json")
    [schema.dig("definitions", "ThreadItem"), schema]
  end

  def test_agent_message_item_validates_against_threaditem
    sub_schema, root = threaditem_schema_with_root
    item = Fixtures::Codex.agent_message_item(text: "hi")
    assert_valid(sub_schema, item, "agent_message_item",
                 root_schema: root)
  end

  def test_mcp_tool_call_item_validates_against_threaditem
    sub_schema, root = threaditem_schema_with_root
    item = Fixtures::Codex.mcp_tool_call_item(tool: "shell", server: "exec")
    assert_valid(sub_schema, item, "mcp_tool_call_item",
                 root_schema: root)
  end

  # ----- Wrapper shape sanity (no schema, just envelope check) -----

  def test_item_completed_agent_message_wraps_under_item_key
    payload = Fixtures::Codex.item_completed_agent_message(text: "hello")
    assert_kind_of Hash, payload["item"]
    assert_equal "agentMessage", payload.dig("item", "type")
    assert_equal "hello", payload.dig("item", "text")
  end

  def test_item_completed_tool_call_wraps_under_item_key
    payload = Fixtures::Codex.item_completed_tool_call(tool: "shell")
    assert_kind_of Hash, payload["item"]
    assert_equal "mcpToolCall", payload.dig("item", "type")
    assert_equal "shell", payload.dig("item", "tool")
  end

  # ----- ThreadTokenUsageUpdatedNotification -----

  def test_thread_token_usage_updated_notification_validates_against_schema
    notif = Fixtures::Codex.thread_token_usage_updated_notification(
      thread_id: "thr-1", turn_id: "trn-1"
    )
    assert_valid(load_schema("v2/ThreadTokenUsageUpdatedNotification.json"), notif,
                 "thread_token_usage_updated_notification")
    assert_equal "thr-1", notif["threadId"]
    assert_equal "trn-1", notif["turnId"]
    assert_equal 0, notif.dig("tokenUsage", "total", "inputTokens")
  end

  def test_thread_token_usage_updated_notification_with_realistic_totals
    usage = Fixtures::Codex.thread_token_usage(
      total: Fixtures::Codex.token_usage_breakdown(
        input_tokens: 197_819,
        output_tokens: 25_018,
        cached_input_tokens: 6_408_576,
        reasoning_output_tokens: 12_501,
        total_tokens: 222_837
      )
    )
    notif = Fixtures::Codex.thread_token_usage_updated_notification(
      thread_id: "thr-1", turn_id: "trn-1", token_usage: usage
    )
    assert_valid(load_schema("v2/ThreadTokenUsageUpdatedNotification.json"), notif,
                 "thread_token_usage_updated_notification (realistic totals)")
    assert_equal 197_819, notif.dig("tokenUsage", "total", "inputTokens")
    assert_equal 6_408_576, notif.dig("tokenUsage", "total", "cachedInputTokens")
  end
end
