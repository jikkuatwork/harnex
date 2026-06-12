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
    assert payload.key?(:task_failed), "missing task_failed"
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
    assert_equal false, payload[:task_failed]
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

  def test_error_notification_populates_last_error_without_auto_disconnect
    @session.send(:handle_rpc_notification, {
      "method" => "error",
      "params" => { "error" => { "message" => "boom" }, "turnId" => "trn-err" }
    })
    payload = @session.status_payload(include_input_state: false)
    assert_equal "boom", payload[:last_error]
    assert_equal 0, payload[:auto_disconnects]
  end

  def test_failed_turn_sets_failed_work_state
    @session.send(:handle_rpc_notification, {
      "method" => "turn/completed",
      "params" => { "turn" => { "id" => "trn-fail", "status" => "failed", "error" => { "message" => "nope" } } }
    })
    payload = @session.status_payload(include_input_state: false)
    assert_equal false, payload[:task_complete]
    assert_equal true, payload[:task_failed]
    assert_equal false, payload[:done]
    assert_equal "failed", payload[:work_state]
    assert_equal "nope", payload[:last_error]
  end
end
