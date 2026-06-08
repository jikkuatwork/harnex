require_relative "../../test_helper"
require "json"

class StatusJsonrpcFieldsTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("harnex-status-test")
    adapter = Harnex::Adapters::CodexAppServer.new
    @session = Harnex::Session.new(
      adapter: adapter,
      command: ["codex", "app-server"],
      repo_root: @tmp,
      host: "127.0.0.1",
      id: "test-status",
      meta: { "model" => "gpt-5", "effort" => "high" }
    )
    @session.send(:prepare_output_log)
    @session.send(:prepare_events_log)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_status_includes_new_fields
    payload = @session.status_payload(include_input_state: false)
    assert payload.key?(:last_completed_at), "missing last_completed_at"
    assert payload.key?(:task_complete), "missing task_complete"
    assert payload.key?(:done), "missing done"
    assert payload.key?(:work_state), "missing work_state"
    assert payload.key?(:process_state), "missing process_state"
    assert payload.key?(:model), "missing model"
    assert payload.key?(:effort), "missing effort"
    assert payload.key?(:auto_disconnects), "missing auto_disconnects"
    assert_equal "gpt-5", payload[:model]
    assert_equal "high", payload[:effort]
    assert_nil payload[:last_completed_at]
    assert_equal false, payload[:task_complete]
    assert_equal false, payload[:done]
    assert_equal "running", payload[:work_state]
    assert_equal "running", payload[:process_state]
    assert_equal 0, payload[:auto_disconnects]
  end

  def test_last_completed_at_populates_after_turn_completed
    @session.send(:handle_rpc_notification, { "method" => "turn/completed", "params" => { "turnId" => "x" } })
    payload = @session.status_payload(include_input_state: false)
    refute_nil payload[:last_completed_at]
    assert_equal true, payload[:task_complete]
    assert_equal true, payload[:done]
    assert_equal "completed", payload[:work_state]
    assert_equal "running", payload[:process_state]
  end

  def test_auto_disconnects_increments_on_error_notification
    @session.send(:handle_rpc_notification, { "method" => "error", "params" => { "message" => "boom" } })
    payload = @session.status_payload(include_input_state: false)
    assert_equal 1, payload[:auto_disconnects]
  end
end
