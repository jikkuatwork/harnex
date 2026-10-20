require_relative "../../test_helper"
require "json"
require "timeout"

# Completion, receipt and exit-classification behavior shared by every
# structured session, exercised through the Pi adapter (moved here from the
# Codex app-server tests when Codex was removed in 0.20.0).
class SessionCompletionSharedTest < Minitest::Test
  class RecordingCompletionNotifier
    attr_reader :calls

    def initialize(receipt_path)
      @receipt_path = receipt_path
      @calls = []
    end

    def register! = true

    def notify(**snapshot)
      @calls << snapshot.merge(receipt_present: File.file?(@receipt_path))
      true
    end
  end

  def setup
    @tmp = Dir.mktmpdir("harnex-shared-completion")
    system("git", "init", "-q", @tmp, out: File::NULL, err: File::NULL)
    @session = build_session(id: "pi-shared")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def build_session(id:, **options)
    adapter = Harnex::Adapters::Pi.new
    Harnex::Session.new(adapter: adapter, command: ["pi", "--mode", "rpc"], repo_root: @tmp,
                        host: "127.0.0.1", id: id, **options).tap do |session|
      session.send(:prepare_output_log)
      session.send(:prepare_events_log)
    end
  end

  def notify(session, message)
    session.send(:handle_jsonl_notification, message)
  end

  def settle(session, stop_reason: "stop", error: nil)
    assistant = { "role" => "assistant", "content" => [], "stopReason" => stop_reason, "timestamp" => rand(1_000_000) }
    assistant["errorMessage"] = error if error
    notify(session, { "type" => "agent_start" })
    notify(session, { "type" => "agent_end", "messages" => [assistant], "willRetry" => false })
    notify(session, { "type" => "agent_settled" })
  end

  def close_logs(session)
    [:@events_log, :@output_log].each do |ivar|
      io = session&.instance_variable_get(ivar)
      io&.close unless io&.closed?
    end
  end

  def with_completion_notifier_session(name)
    receipt_path = File.join(@tmp, "#{name}-receipt.json")
    notifier = RecordingCompletionNotifier.new(receipt_path)
    session = build_session(id: "notify-#{name}", artifact_report_path: receipt_path, completion_notifier: notifier)
    session.send(:emit_git_start_event)
    session.send(:register_completion_notifier!)
    yield session, notifier
  ensure
    close_logs(session)
  end

  def test_harness_generates_no_change_receipt_and_attaches_review_claims
    File.write(File.join(@tmp, "README.md"), "receipt test\n")
    system("git", "-C", @tmp, "add", "README.md", out: File::NULL, err: File::NULL)
    system("git", "-C", @tmp, "-c", "user.email=test@example.com", "-c", "user.name=Test",
           "commit", "-q", "-m", "initial", out: File::NULL, err: File::NULL)
    session = build_session(id: "observed-no-change", require_artifact_report: true)
    session.send(:emit_git_start_event)
    File.write(session.artifact_claims_path, JSON.generate(
      claims: { summary: "Review completed without repository changes.", verdict: "changes_requested",
                findings: { P1: 0, P2: 1, P3: 0 } }
    ))
    notify(session, { "type" => "agent_start" })
    notify(session, { "type" => "tool_execution_start", "toolCallId" => "c1", "toolName" => "bash",
                      "args" => { "command" => "git diff --check" } })
    notify(session, { "type" => "tool_execution_end", "toolCallId" => "c1", "toolName" => "bash",
                      "result" => { "structuredContent" => { "exit_code" => 0 } }, "isError" => false })
    settle(session)

    completed = File.readlines(session.events_log_path).map { |line| JSON.parse(line) }
                    .find { |event| event["type"] == "task_complete" }
    assert_equal ["completed_with_proof", "accepted"], completed.values_at("outcome_class", "artifact_report_status")
    result = Harnex::ArtifactReport.validate(session.artifact_report_path, final: true)
    assert result.ok
    assert_equal "no_change", result.report.dig("outcome", "status")
    assert_equal "harnex", result.report.dig("receipt", "author")
    assert_equal "changes_requested", result.report.dig("claims", "verdict")
    assert_equal 1, result.report.dig("claims", "findings", "P2")
    assert session.task_complete?
  ensure
    close_logs(session)
  end

  def test_classify_exit_marks_short_pre_turn_exit_as_boot_failure
    @session.instance_variable_set(:@exit_code, nil)
    @session.instance_variable_set(:@ended_at, @session.instance_variable_get(:@started_at) + 1)

    assert_equal "boot_failure", @session.send(:classify_exit)
  end

  def test_classify_exit_keeps_post_turn_short_exit_as_disconnected
    notify(@session, { "type" => "turn_start" })
    @session.instance_variable_set(:@exit_code, 0)
    @session.instance_variable_set(:@ended_at, @session.instance_variable_get(:@started_at) + 1)

    assert_equal "disconnected", @session.send(:classify_exit)
  end

  def test_classify_exit_keeps_late_pre_turn_exit_as_disconnected
    @session.instance_variable_set(:@exit_code, 0)
    @session.instance_variable_set(:@ended_at, @session.instance_variable_get(:@started_at) + 6)

    assert_equal "disconnected", @session.send(:classify_exit)
  end

  def test_failed_turn_classifies_the_exit_as_failure
    notify(@session, { "type" => "turn_start" })
    settle(@session, stop_reason: "error", error: "Missing environment variable: `AZURE_OPENAI_API_KEY`.")
    @session.instance_variable_set(:@exit_code, 0)
    @session.instance_variable_set(:@ended_at, @session.instance_variable_get(:@started_at) + 2)

    assert_equal "failure", @session.send(:classify_exit)
  end

  def test_completion_notifier_receives_each_typed_outcome_once_after_receipt
    cases = {
      "accepted" => ["completed", "task_complete", "completed_with_proof"],
      "rejected" => ["rejected", "task_failed", "completed_no_activity"],
      "failed" => ["failed", "task_failed", nil],
      "dispatch-error" => ["error", "dispatch_error", nil]
    }

    cases.each do |name, (outcome, signal, outcome_class)|
      with_completion_notifier_session(name) do |session, notifier|
        case name
        when "accepted" then session.send(:record_successful_completion, {})
        when "rejected" then session.send(:mark_task_failed, status: outcome_class, outcome_class: outcome_class)
        when "failed" then session.send(:mark_task_failed, status: "failed")
        else session.send(:mark_task_failed, status: "dispatch_error", error: "send failed")
        end

        snapshot = notifier.calls.fetch(0)
        assert_equal [outcome, outcome == "completed" ? "completed" : "failed", signal, outcome_class, true],
                     snapshot.values_at(:outcome, :work_state, :terminal_signal, :outcome_class, :receipt_present), name
        session.instance_variable_set(:@exit_code, 0)
        session.send(:finalize_session!)
        assert_equal 1, notifier.calls.length, name
      end
    end
  end

  def test_first_terminal_callback_owns_notification_while_receipt_is_written
    with_completion_notifier_session("terminal-race") do |session, notifier|
      entered = Queue.new
      release = Queue.new
      original = session.method(:persist_observed_receipt!)
      session.define_singleton_method(:persist_observed_receipt!) do
        entered << true
        release.pop
        original.call
      end

      accepted = Thread.new { session.send(:record_successful_completion, {}) }
      entered.pop
      session.define_singleton_method(:persist_observed_receipt!) { original.call }
      failed = Thread.new { session.send(:mark_task_failed, status: "failed") }
      release << true
      [accepted, failed].each(&:join)

      assert_equal ["completed", "task_complete"], notifier.calls.fetch(0).values_at(:outcome, :terminal_signal)
      assert_equal 1, notifier.calls.length
    end
  end

  def test_terminal_callback_waits_for_registration_cleanup_then_notifies
    with_completion_notifier_session("registration-race") do |session, notifier|
      cleanup_started, release, publish_started = 3.times.map { Queue.new }
      notifier.define_singleton_method(:register!) { cleanup_started << true; release.pop; true }
      original = session.method(:completion_notification_snapshot)
      session.define_singleton_method(:completion_notification_snapshot) do |signal|
        publish_started << true
        original.call(signal)
      end
      session.instance_variable_set(:@completion_notification_registered, false)

      registration = Thread.new { session.send(:register_completion_notifier!) }
      cleanup_started.pop
      terminal = Thread.new { session.send(:mark_task_failed, status: "failed") }
      Timeout.timeout(2) { publish_started.pop }
      release << true
      [registration, terminal].each(&:join)

      assert_equal ["failed", "task_failed"], notifier.calls.fetch(0).values_at(:outcome, :terminal_signal)
      assert_equal 1, notifier.calls.length
    end
  end

  def test_finalization_without_typed_work_notifies_error_once
    with_completion_notifier_session("finalization") do |session, notifier|
      session.instance_variable_set(:@exit_code, 0)
      2.times { session.send(:finalize_session!) }

      snapshot = notifier.calls.fetch(0)
      assert_equal ["error", "failed", "finalization", true],
                   snapshot.values_at(:outcome, :work_state, :terminal_signal, :receipt_present)
      assert_equal 1, notifier.calls.length
    end
  end
end
