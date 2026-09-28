require_relative "../../test_helper"

class ActivityTrackerTest < Minitest::Test
  def setup
    @mono = 10.0
    @wall = Time.utc(2026, 9, 28, 12)
    @tracker = tracker(:stdio_jsonl_rpc)
  end

  def tracker(transport)
    Harnex::ActivityTracker.new(
      transport: transport,
      monotonic_clock: -> { @mono },
      wall_clock: -> { @wall }
    )
  end

  def advance(seconds)
    @mono += seconds
    @wall += seconds
  end

  def pi(type, **payload)
    @tracker.observe_pi({ "type" => type }.merge(payload.transform_keys(&:to_s)))
  end

  def test_ui_chatter_and_retries_do_not_advance_work_clocks_or_reset_turn
    pi("agent_start")
    pi("message_start", message: { "role" => "assistant" })
    initial = @tracker.snapshot
    advance(20)
    pi("extension_ui_request", method: "setStatus", statusText: "alive")
    pi("queue_update", steering: ["hello"])
    pi("auto_retry_start")
    pi("agent_end")
    pi("agent_start")

    current = @tracker.snapshot
    assert_equal true, current[:turn_active]
    assert_equal true, current[:model_active]
    assert_equal initial[:turn_started_at], current[:turn_started_at]
    assert_equal initial[:last_model_activity_at], current[:last_model_activity_at]
    assert_equal 20.0, current[:turn_age_s]
    assert_equal 20.0, current[:model_age_s]
    assert_equal 20.0, current[:model_idle_s]
    assert_nil current[:last_tool_activity_at]
  end

  def test_thinking_is_activity_but_never_retained
    pi("agent_start")
    pi("message_start", message: { "role" => "assistant" })
    advance(3)
    pi("message_update", assistantMessageEvent: {
      "type" => "thinking_delta", "delta" => "private-thinking-sentinel"
    })
    current = @tracker.snapshot
    assert_equal @wall.iso8601(3), current[:last_model_activity_at]
    assert_equal 0.0, current[:model_idle_s]
    assert_nil current[:last_tool_activity_at]
    refute_includes JSON.generate(current), "private-thinking-sentinel"
    refute_includes @tracker.inspect, "private-thinking-sentinel"
  end

  def test_model_and_tool_clocks_are_separate
    pi("agent_start")
    pi("message_start", message: { "role" => "assistant" })
    advance(1)
    pi("message_end", message: { "role" => "assistant" })
    advance(2)
    pi("tool_execution_start", args: { "secret" => "not-retained" })
    advance(4)
    pi("tool_execution_update")
    current = @tracker.snapshot
    assert_equal false, current[:model_active]
    assert_nil current[:model_age_s]
    assert_equal 6.0, current[:model_idle_s]
    assert_equal 0.0, current[:tool_idle_s]
    assert_equal 7.0, current[:turn_age_s]
    refute_includes @tracker.inspect, "not-retained"
  end

  def test_quiet_generation_is_active_until_settlement_then_new_turn_resets_clocks
    pi("agent_start")
    pi("message_start", message: { "role" => "assistant" })
    advance(60)
    assert_equal true, @tracker.snapshot[:model_active]
    assert_equal 60.0, @tracker.snapshot[:model_age_s]
    pi("message_end", message: { "role" => "assistant" })
    pi("agent_settled")
    assert_equal false, @tracker.snapshot[:turn_active]
    assert_equal false, @tracker.snapshot[:model_active]
    assert_nil @tracker.snapshot[:turn_age_s]
    advance(5)
    @tracker.start_turn
    assert_equal true, @tracker.snapshot[:turn_active]
    assert_equal 0.0, @tracker.snapshot[:turn_age_s]
    assert_nil @tracker.snapshot[:last_model_activity_at]
    assert_nil @tracker.snapshot[:last_tool_activity_at]
  end

  def test_non_assistant_and_empty_updates_are_not_model_progress
    pi("agent_start")
    pi("message_start", message: { "role" => "user" })
    pi("message_end", message: { "role" => "toolResult" })
    pi("message_update", assistantMessageEvent: { "type" => "text_delta", "delta" => "" })
    assert_nil @tracker.snapshot[:last_model_activity_at]
    assert_equal false, @tracker.snapshot[:model_active]
  end

  def test_wall_clock_changes_do_not_distort_ages
    pi("agent_start")
    pi("message_start", message: { "role" => "assistant" })
    @mono += 8
    @wall -= 3_600
    assert_equal 8.0, @tracker.snapshot[:turn_age_s]
    assert_equal 8.0, @tracker.snapshot[:model_idle_s]
  end

  def test_pty_work_is_unknown_even_when_output_or_events_exist
    unknown = tracker(:pty)
    unknown.start_turn
    unknown.observe_pi("type" => "message_start", "message" => { "role" => "assistant" })
    snapshot = unknown.snapshot
    assert_equal "unknown", snapshot[:status]
    assert_nil snapshot[:turn_active]
    assert_nil snapshot[:model_active]
    assert_nil snapshot[:last_model_activity_at]
    assert_nil snapshot[:last_tool_activity_at]
  end

  def test_codex_model_and_tool_notifications_use_the_same_clock_contract
    codex = tracker(:stdio_jsonrpc)
    codex.observe_rpc("method" => "turn/started")
    codex.observe_rpc("method" => "item/reasoning/textDelta", "params" => { "delta" => "hidden" })
    advance(4)
    codex.observe_rpc("method" => "item/completed", "params" => { "item" => { "type" => "reasoning" } })
    advance(2)
    codex.observe_rpc("method" => "item/commandExecution/outputDelta", "params" => { "delta" => "output" })
    assert_equal 2.0, codex.snapshot[:model_idle_s]
    assert_equal 0.0, codex.snapshot[:tool_idle_s]
    codex.observe_rpc("method" => "turn/completed")
    assert_equal false, codex.snapshot[:turn_active]
    refute_includes codex.inspect, "hidden"
  end
end
