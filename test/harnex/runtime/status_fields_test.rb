require_relative "../../test_helper"
require "json"

class StatusFieldsTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("harnex-status-test")
    @session = Harnex::Session.new(
      adapter: Harnex::Adapters::Pi.new,
      command: ["pi", "--mode", "rpc"],
      repo_root: @tmp,
      host: "127.0.0.1",
      id: "test-status",
      meta: { "model" => "foundry-zyt/gpt-6.1-sol", "effort" => "high" }
    )
    @session.send(:prepare_output_log)
    @session.send(:prepare_events_log)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def settle(stop_reason, error: nil)
    assistant = { "role" => "assistant", "content" => [], "stopReason" => stop_reason, "timestamp" => 1 }
    assistant["errorMessage"] = error if error
    @session.send(:handle_jsonl_notification, { "type" => "agent_start" })
    @session.send(:handle_jsonl_notification, { "type" => "agent_end", "messages" => [assistant], "willRetry" => false })
    @session.send(:handle_jsonl_notification, { "type" => "agent_settled" })
  end

  def test_status_includes_new_fields
    payload = @session.status_payload(include_input_state: false)
    %i[last_completed_at task_complete task_failed done work_state process_state model effort auto_disconnects].each do |key|
      assert payload.key?(key), "missing #{key}"
    end
    assert_equal "foundry-zyt/gpt-6.1-sol", payload[:model]
    assert_equal "high", payload[:effort]
    assert_nil payload[:last_completed_at]
    assert_equal [false, false, false], payload.values_at(:task_complete, :task_failed, :done)
    assert_equal ["running", "running", 0], payload.values_at(:work_state, :process_state, :auto_disconnects)
  end

  def test_last_completed_at_populates_after_a_settled_turn
    settle("stop")
    payload = @session.status_payload(include_input_state: false)
    refute_nil payload[:last_completed_at]
    assert_equal [true, true, "completed", "running"], payload.values_at(:task_complete, :done, :work_state, :process_state)
  end

  def test_extension_error_populates_last_error_without_auto_disconnect
    @session.send(:handle_jsonl_notification, { "type" => "extension_error", "error" => "boom" })
    payload = @session.status_payload(include_input_state: false)
    assert_equal "boom", payload[:last_error]
    assert_equal 0, payload[:auto_disconnects]
  end

  def test_failed_turn_sets_failed_work_state
    settle("error", error: "nope")
    payload = @session.status_payload(include_input_state: false)
    assert_equal [false, true, false, "failed", "nope"],
                 payload.values_at(:task_complete, :task_failed, :done, :work_state, :last_error)
  end
end
