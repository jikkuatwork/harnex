require_relative "../../test_helper"
require "timeout"
require "rbconfig"

# Exercise the real Pi JSONL reader, wait thread, receipts and registry lifecycle
# without a model, credentials, or an installed Pi process.
class SessionPiStopTest < Minitest::Test
  CHILD = <<~'RUBY'
    require "json"
    STDOUT.sync = true
    def emit(value)
      puts JSON.generate(value)
    end
    trap("USR1") { exit! 0 }
    trap("USR2") { exit! 143 }
    while line = STDIN.gets
      command = JSON.parse(line)
      data = case command["type"]
             when "get_state"
               { "isStreaming" => false, "sessionId" => "fixture-pi" }
             when "get_session_stats"
               { "tokens" => { "input" => 12, "output" => 6, "total" => 18 }, "cost" => 0.01 }
             else
               {}
             end
      emit("type" => "response", "command" => command["type"], "id" => command["id"], "success" => true, "data" => data)
      next unless command["type"] == "prompt"

      emit("type" => "agent_start")
      emit("type" => "turn_start")
      text = command["message"]
      next if text == "busy"
      File.write("result.txt", text) if text.start_with?("change")
      if text == "malformed-on-stop"
        trap("TERM") { puts "{broken"; exit! 143 }
      elsif text == "kill-on-stop"
        trap("TERM") { Process.kill("KILL", Process.pid) }
      elsif text == "exit143-on-stop"
        # Current Pi handles SIGTERM with process.exit(143), not a signal exit.
        trap("TERM") { exit! 143 }
      end
      assistant = { "role" => "assistant", "content" => [], "stopReason" => text == "error" ? "error" : "stop" }
      emit("type" => "message_end", "message" => assistant)
      emit("type" => "agent_end", "messages" => [assistant], "willRetry" => false)
      emit("type" => "agent_settled")
    end
  RUBY

  def setup
    @tmp = Dir.mktmpdir("harnex-pi-stop")
    git("init", "-q")
    git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "baseline")
    @adapter = Harnex::Adapters::Pi.new
    @adapter.define_singleton_method(:validate_runtime!) { true }
    @adapter.define_singleton_method(:agent_version) { "0.84.4-fixture" }
    @adapter.define_singleton_method(:build_command) { [RbConfig.ruby, "-e", CHILD] }
    @session = Harnex::Session.new(
      adapter: @adapter, command: @adapter.build_command, repo_root: @tmp,
      host: "127.0.0.1", id: "pi-stop"
    )
    # Session.run normally owns the main thread's signal handlers.
    @session.define_singleton_method(:install_signal_handlers) {}
  end

  def teardown
    reap_process(@session.pid)
    reap_thread(@runner)
    @adapter.close rescue nil
    FileUtils.rm_rf(@tmp)
  end

  def test_idle_stop_preserves_accepted_receipt_and_raw_child_status
    start_session
    complete_turn("change-one")
    before = receipt
    assert_equal "accepted", before.dig("outcome", "status")

    stop_and_finish

    assert_preserved_completion(before)
    assert_equal [143, 15], events.find { |row| row["type"] == "process_exited" }.values_at("code", "signal")
  end

  def test_idle_stop_preserves_no_change_receipt
    start_session
    complete_turn("exit143-on-stop")
    before = receipt
    assert_equal "no_change", before.dig("outcome", "status")

    stop_and_finish

    assert_preserved_completion(before)
    assert_equal [143, nil], events.find { |row| row["type"] == "process_exited" }.values_at("code", "signal")
  end

  def test_two_turns_then_idle_stop_preserves_latest_settlement
    start_session
    complete_turn("change-one")
    first = @session.instance_variable_get(:@last_completed_at)
    complete_turn("change-two")
    before = receipt
    latest = @session.instance_variable_get(:@last_completed_at)

    stop_and_finish

    assert_preserved_completion(before)
    assert_equal latest, @session.instance_variable_get(:@last_completed_at)
    assert_equal 2, events.count { |row| row["type"] == "task_complete" }
    assert_equal 2, end_row.dig("actual", "turn_count")
    assert_equal "change-two", File.read(File.join(@tmp, "result.txt"))
    assert_operator latest, :>, first
  end

  def test_busy_followup_stop_cannot_reuse_previous_proof_or_late_success
    start_session
    complete_turn("change-one")
    send_prompt("busy")
    wait_until { events.count { |row| row["type"] == "turn_started" } == 2 }
    refute @session.task_complete?, "a new prompt must invalidate the previous accepted turn"

    release = hold_termination
    @session.inject_stop
    late_settlement
    release << true
    finish

    assert_rejected
    assert_equal 1, events.count { |row| row["type"] == "task_complete" }
  ensure
    release << true if release
  end

  def test_pending_dispatch_invalidates_proof_before_prompt_response_or_agent_start
    start_session
    complete_turn("no-change")
    entered = Queue.new
    release = Queue.new
    original = @adapter.method(:dispatch)
    @adapter.define_singleton_method(:dispatch) do |**args|
      entered << true
      release.pop
      original.call(**args)
    end
    sender = Thread.new { send_prompt("busy") rescue nil }
    Timeout.timeout(3) { entered.pop }

    refute @session.task_complete?, "dispatch reservation must clear proof before waiting for RPC"
    @session.send(:handle_jsonl_notification, {
      "type" => "agent_end", "messages" => [{ "role" => "assistant", "stopReason" => "stop" }]
    })
    @session.send(:handle_jsonl_notification, { "type" => "agent_settled" })
    refute @session.task_complete?, "a stale settlement without a new run start cannot prove this dispatch"
    stopper = Thread.new { @session.inject_stop }
    wait_until { @session.instance_variable_get(:@stop_requested) }
    late_settlement
    release << true
    assert sender.join(3)
    assert stopper.join(3)
    finish
    assert_rejected
  ensure
    release << true if release
    reap_thread(sender)
    reap_thread(stopper)
  end

  def test_idle_stop_rejects_new_dispatch_and_ignores_late_terminal_events
    start_session
    complete_turn("no-change")
    before = receipt
    release = hold_termination
    @session.inject_stop
    late_settlement(reason: "aborted")

    assert_raises(RuntimeError, ArgumentError) { send_prompt("busy", force: true) }
    release << true
    finish

    assert_preserved_completion(before)
    assert_equal 1, events.count { |row| row["type"] == "task_complete" }
    refute events.any? { |row| row["type"] == "task_failed" }
  ensure
    release << true if release
  end

  def test_dispatch_bookkeeping_after_stop_cannot_recreate_live_registry
    start_session
    entered = Queue.new
    release = Queue.new
    original = @adapter.method(:dispatch)
    @adapter.define_singleton_method(:dispatch) do |**args|
      result = original.call(**args)
      entered << true
      release.pop
      result
    end
    sender = Thread.new { send_prompt("no-change") }
    Timeout.timeout(3) { entered.pop }
    wait_until { @session.task_complete? }
    stop_and_finish
    release << true
    assert sender.join(3)

    refute File.exist?(Harnex.registry_path(@tmp, @session.id)), "late send bookkeeping must not resurrect a stopped session"
    assert Harnex::ArtifactReport.validate(@session.artifact_report_path, final: true).ok
  ensure
    release << true if release
    reap_thread(sender)
  end

  def test_unexpected_sigterm_after_settlement_is_not_cleanup
    start_session
    complete_turn("no-change")
    Process.kill("TERM", @session.pid)
    finish

    assert_rejected
    assert_equal 1, end_row.dig("reliability", "real_disconnections")
  end

  def test_unexpected_exit143_without_idle_stop_does_not_preserve_proof
    start_session
    complete_turn("no-change")
    Process.kill("USR2", @session.pid)
    finish

    assert_rejected
    assert_equal "lost", end_row.dig("reliability", "adapter_close")
    assert_equal 1, end_row.dig("reliability", "real_disconnections")
  end

  def test_unexpected_zero_exit_after_settlement_is_still_transport_failure
    start_session
    complete_turn("no-change")
    Process.kill("USR1", @session.pid)
    finish

    assert_rejected
    assert_equal "lost", end_row.dig("reliability", "adapter_close")
    assert_equal 1, end_row.dig("reliability", "real_disconnections")
  end

  def test_malformed_transport_during_idle_shutdown_is_not_accepted
    start_session
    complete_turn("malformed-on-stop")
    stop_and_finish

    assert_rejected
    assert_equal 1, end_row.dig("reliability", "real_disconnections")
  end

  def test_idle_stop_does_not_accept_an_arbitrary_termination_signal
    start_session
    complete_turn("kill-on-stop")
    stop_and_finish

    assert_rejected
    assert_equal [137, 9], events.find { |row| row["type"] == "process_exited" }.values_at("code", "signal")
  end

  def test_auto_stop_still_preserves_settled_success
    @session.instance_variable_set(:@auto_stop, true)
    start_session
    send_prompt("no-change")
    finish

    assert_equal 0, @runner.value
    assert Harnex::ArtifactReport.validate(@session.artifact_report_path, final: true).ok
    assert_equal "normal", end_row.dig("reliability", "adapter_close")
    assert_equal 0, end_row.dig("reliability", "real_disconnections")
  end

  def test_auto_stop_preserves_failed_settlement_without_false_disconnection
    @session.instance_variable_set(:@auto_stop, true)
    start_session
    send_prompt("error")
    finish

    assert_rejected
    assert_equal 0, end_row.dig("reliability", "real_disconnections")
    assert_equal "normal", end_row.dig("reliability", "adapter_close")
  end

  def test_idle_stop_waits_for_in_progress_receipt_before_deciding
    start_session
    entered = Queue.new
    release = Queue.new
    original = @session.method(:persist_observed_receipt!)
    @session.define_singleton_method(:persist_observed_receipt!) do
      entered << true
      release.pop
      original.call
    end
    send_prompt("no-change")
    Timeout.timeout(3) { entered.pop }
    stopper = Thread.new { @session.inject_stop }
    @session.define_singleton_method(:persist_observed_receipt!) { original.call }
    release << true
    assert stopper.join(3)
    finish

    assert_equal 0, @runner.value
    assert Harnex::ArtifactReport.validate(@session.artifact_report_path, final: true).ok
    assert_equal 0, end_row.dig("reliability", "real_disconnections")
  ensure
    release << true if release
    reap_thread(stopper)
  end

  private

  def hold_termination
    release = Queue.new
    gate = release
    original = @adapter.method(:terminate_subprocess)
    @adapter.define_singleton_method(:terminate_subprocess) do |**args|
      waiting, gate = gate, nil
      waiting&.pop
      original.call(**args)
    end
    release
  end

  def git(*args)
    raise "git fixture setup failed" unless system("git", "-C", @tmp, *args, out: File::NULL, err: File::NULL)
  end

  def start_session
    @runner = Thread.new { @session.run(validate_binary: false) }
    @runner.report_on_exception = false
    wait_until { File.file?(Harnex.registry_path(@tmp, @session.id)) && @adapter.state == :prompt }
  end

  def send_prompt(text, force: false)
    @session.inject_via_adapter(text: text, submit: true, enter_only: false, force: force)
  end

  def complete_turn(text)
    count = events.count { |row| row["type"] == "task_complete" }
    send_prompt(text)
    wait_until { events.count { |row| row["type"] == "task_complete" } == count + 1 }
  end

  def stop_and_finish
    @session.inject_stop
    assert_equal "already_requested", @session.inject_stop[:signal]
    finish
  end

  def finish
    assert @runner.join(5), "session should exit and finalize promptly"
    @runner.value
    @session.send(:finalize_session!)
    refute File.exist?(Harnex.registry_path(@tmp, @session.id)), "live registry must be removed"
    rows = File.readlines(Harnex::DispatchHistory.path_for(@tmp)).map { |line| JSON.parse(line) }
    assert_equal 1, rows.count { |row| row["record_type"] == "dispatch_end" }
    assert_equal 1, events.count { |row| row["type"] == "exited" }
  end

  def assert_preserved_completion(before)
    assert_equal 0, @runner.value
    result = Harnex::ArtifactReport.validate(@session.artifact_report_path, final: true)
    assert result.ok, result.diagnostics.inspect
    assert_equal before.dig("outcome", "status"), result.report.dig("outcome", "status")
    assert_equal true, result.report.dig("observed", "turn", "accepted")
    assert_equal true, result.report.dig("observed", "turn", "task_complete")
    assert_equal "success", end_row.dig("actual", "exit")
    assert_equal "normal", end_row.dig("reliability", "adapter_close")
    assert_equal 0, end_row.dig("reliability", "real_disconnections")
    assert_equal 18, end_row.dig("usage", "total_tokens")
    assert_equal 0.01, end_row.dig("usage", "cost_usd")
  end

  def assert_rejected
    refute_equal 0, @runner.value
    refute Harnex::ArtifactReport.validate(@session.artifact_report_path, final: true).ok
    assert_equal "rejected", end_row.dig("outcome", "status")
    assert_equal false, receipt.dig("observed", "turn", "accepted")
  end

  def late_settlement(reason: "stop")
    @session.send(:handle_jsonl_notification, { "type" => "agent_start" })
    @session.send(:handle_jsonl_notification, {
      "type" => "agent_end", "messages" => [{ "role" => "assistant", "stopReason" => reason }]
    })
    @session.send(:handle_jsonl_notification, { "type" => "agent_settled" })
  end

  def receipt
    JSON.parse(File.read(@session.artifact_report_path))
  end

  def end_row
    JSON.parse(File.readlines(Harnex::DispatchHistory.path_for(@tmp)).last)
  end

  def events
    File.readlines(@session.events_log_path).filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil # A writer may be between its JSON and LF writes.
    end
  end

  def wait_until
    Timeout.timeout(5) do
      sleep 0.005 until yield
    end
  end
end
