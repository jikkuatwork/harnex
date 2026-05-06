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
    assert payload.key?(:model), "missing model"
    assert payload.key?(:effort), "missing effort"
    assert payload.key?(:auto_disconnects), "missing auto_disconnects"
    assert_equal "gpt-5", payload[:model]
    assert_equal "high", payload[:effort]
    assert_nil payload[:last_completed_at]
    assert_equal 0, payload[:auto_disconnects]
  end

  def test_last_completed_at_populates_after_turn_completed
    @session.send(:handle_rpc_notification, { "method" => "turn/completed", "params" => { "turnId" => "x" } })
    payload = @session.status_payload(include_input_state: false)
    refute_nil payload[:last_completed_at]
  end

  def test_auto_disconnects_increments_on_error_notification
    @session.send(:handle_rpc_notification, { "method" => "error", "params" => { "message" => "boom" } })
    payload = @session.status_payload(include_input_state: false)
    assert_equal 1, payload[:auto_disconnects]
  end
end
