require_relative "../../test_helper"

class SessionControlsTest < Minitest::Test
  class PiFixture < Harnex::Adapters::Pi
    attr_reader :terminations

    def initialize
      super
      @state = :prompt
      @terminations = 0
    end

    def terminate_subprocess(**_kwargs)
      @terminations += 1
      true
    end

    def interrupt(**_kwargs)
      nil
    end

    def collect_session_summary
      {}
    end

    def agent_version
      "0.87.1"
    end

    def request_session_stats_async
      nil
    end
  end

  def setup
    @repo = Dir.mktmpdir("harnex-session-controls")
    @adapter = PiFixture.new
    @session = Harnex::Session.new(
      adapter: @adapter, command: ["pi"], repo_root: @repo,
      host: "127.0.0.1", id: "controls", max_runtime_s: 30
    )
    @session.send(:prepare_output_log)
    @session.send(:prepare_events_log)
    @adapter.on_notification { |event| @session.send(:handle_structured_notification, event) }
    @adapter.on_disconnect { |error| @session.send(:handle_structured_disconnect, error) }
  end

  def teardown
    @session.instance_variable_get(:@runtime_budget)&.cancel
    @session.send(:drain_auto_stop_threads)
    [:@output_log, :@events_log].each { |name| @session.instance_variable_get(name)&.close }
    FileUtils.rm_rf(@repo)
  end

  def emit(type, **payload)
    @adapter.send(:handle_event, { "type" => type }.merge(payload.transform_keys(&:to_s)))
  end

  def settle
    emit("agent_start")
    emit("turn_start")
    emit("message_end", message: { "role" => "assistant", "stopReason" => "stop", "content" => [] })
    emit("agent_settled")
    assert @session.task_complete?
  end

  def final_record
    rows = File.readlines(Harnex::DispatchHistory.path_for(@repo)).map { |line| JSON.parse(line) }
    rows.reverse.find { |row| row["session_id"] == @session.session_id && row["record_type"] == "dispatch_end" }
  end

  def finish(code: 143, signal: 15)
    @session.instance_variable_set(:@exit_code, code)
    @session.instance_variable_set(:@term_signal, signal)
    @session.send(:normalize_pi_stop_exit_code!)
    @session.send(:normalize_runtime_exit_code!)
    @session.send(:finalize_session!)
  end

  def expire_budget
    now = 0.0
    budget = Harnex::RuntimeBudget.new(seconds: 30, monotonic_clock: -> { now })
    @session.instance_variable_set(:@runtime_budget, budget)
    @session.send(:start_runtime_budget!)
    @session.send(:runtime_child_started!)
    now = 31.0
    budget.check!
    Timeout.timeout(2) do
      sleep 0.005 until @session.status_payload[:stop]
    end
    @session.send(:drain_auto_stop_threads)
  end

  def test_activity_snapshot_tracks_thinking_but_not_ui_and_keeps_thinking_out_of_logs
    emit("agent_start")
    emit("message_start", message: { "role" => "assistant" })
    emit("message_update", assistantMessageEvent: { "type" => "thinking_delta", "delta" => "secret-thinking-payload" })
    before = @session.status_payload[:activity]
    emit("extension_ui_request", method: "setStatus", statusText: "new status")
    after = @session.status_payload[:activity]
    assert_equal true, after[:turn_active]
    assert_equal true, after[:model_active]
    assert_equal before[:last_model_activity_at], after[:last_model_activity_at]
    assert_nil after[:last_tool_activity_at]
    refute_includes File.read(@session.output_log_path), "secret-thinking-payload"
    refute_includes File.read(@session.events_log_path), "secret-thinking-payload"
  end

  def test_first_stop_context_survives_receipt_status_and_end_row_without_rejecting_idle_work
    settle
    @session.inject_stop(reason: "manual", origin: "cli", interrupt: false)
    @session.inject_stop(reason: "runtime_budget", origin: "runtime", interrupt: false)
    stop = @session.status_payload[:stop]
    assert_equal "manual", stop[:reason]
    assert_equal "cli", stop[:origin]
    assert_equal "completed", stop[:work_state]
    finish
    report = Harnex::ArtifactReport.validate(@session.artifact_report_path, final: true)
    assert report.ok, report.diagnostics.inspect
    assert_equal "manual", report.report.dig("observed", "stop", "reason")
    assert_equal "cli", final_record.dig("stop", "origin")
    terminal = Harnex::TerminalStatus.build_from_summary(final_record, @repo)
    assert_equal "cli", terminal.dig("stop", "origin")
    assert_equal 0, final_record.dig("reliability", "real_disconnections")
    events = File.readlines(@session.events_log_path).map { |line| JSON.parse(line) }
    assert_equal 1, events.count { |row| row["type"] == "stop_requested" }
  end

  def test_runtime_expiry_interrupts_active_work_and_is_not_transport_loss
    emit("agent_start")
    emit("turn_start")
    emit("message_start", message: { "role" => "assistant" })
    expire_budget
    assert @session.task_failed?
    refute @session.task_complete?
    assert_operator @adapter.terminations, :>=, 1
    @session.send(:handle_structured_disconnect, nil)
    finish
    assert_equal 124, @session.exit_code
    assert_equal "runtime_budget", final_record.dig("stop", "reason")
    assert_equal "runtime", final_record.dig("stop", "origin")
    assert_equal "running", final_record.dig("stop", "work_state")
    assert_equal 30.0, final_record.dig("stop", "runtime_limit_s")
    assert_equal "rejected", final_record.dig("outcome", "status")
    assert_equal 0, final_record.dig("reliability", "real_disconnections")
    assert_equal false, @session.status_payload.dig(:activity, :turn_active)
  end

  def test_runtime_cleanup_of_already_settled_work_preserves_proof
    settle
    expire_budget
    @session.send(:handle_structured_disconnect, nil)
    finish
    assert_equal 0, @session.exit_code
    assert @session.task_complete?
    assert_equal "completed", final_record.dig("stop", "work_state")
    assert_equal "runtime_budget", final_record.dig("observed", "stop", "reason")
    assert Harnex::ArtifactReport.validate(@session.artifact_report_path, final: true).ok
  end

  def test_manual_busy_stop_is_interrupted_work_not_a_provider_disconnect
    emit("agent_start")
    @session.inject_stop(reason: "manual", origin: "cli", interrupt: false)
    @session.send(:handle_structured_disconnect, nil)
    finish
    assert @session.task_failed?
    assert_equal "manual", final_record.dig("stop", "reason")
    assert_equal "running", final_record.dig("stop", "work_state")
    assert_equal 0, final_record.dig("reliability", "real_disconnections")
  end
end
