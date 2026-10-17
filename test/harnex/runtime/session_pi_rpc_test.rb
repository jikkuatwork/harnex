require_relative "../../test_helper"
require "json"

class SessionPiRpcTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("harnex-pi-session")
    # A real repo root so the canonical dispatch stream lands under @tmp.
    system("git", "init", "-q", @tmp, out: File::NULL, err: File::NULL)
    @adapter = Harnex::Adapters::Pi.new
    @session = Harnex::Session.new(
      adapter: @adapter,
      command: ["pi", "--mode", "rpc"],
      repo_root: @tmp,
      host: "127.0.0.1",
      id: "pi-jsonl"
    )
    @session.send(:prepare_output_log)
    @session.send(:prepare_events_log)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def events
    File.readlines(@session.events_log_path).map { |line| JSON.parse(line) }
  end

  def output
    File.binread(@session.output_log_path)
  end

  def test_current_message_delta_shape_does_not_duplicate_and_settled_completes
    assistant = {
      "role" => "assistant",
      "content" => [{ "type" => "text", "text" => "Hello from pi" }],
      "stopReason" => "stop",
      "timestamp" => 1
    }
    @session.send(:handle_jsonl_notification, {
      "type" => "message_start",
      "message" => assistant.merge("content" => [])
    })
    @session.send(:handle_jsonl_notification, {
      "type" => "message_update",
      "assistantMessageEvent" => { "type" => "text_delta", "contentIndex" => 0, "delta" => "Hello from pi" }
    })
    @session.send(:handle_jsonl_notification, { "type" => "message_end", "message" => assistant })
    @session.send(:handle_jsonl_notification, {
      "type" => "agent_end", "messages" => [assistant], "willRetry" => false
    })

    refute events.any? { |row| row["type"] == "task_complete" }, "agent_end is not a final completion fence"

    @session.send(:handle_jsonl_notification, { "type" => "agent_settled" })

    assert_equal 1, output.scan("Hello from pi").length
    assert events.any? { |row| row["type"] == "agent_settled" }
    assert events.any? { |row| row["type"] == "task_complete" }
  end

  def test_agent_error_fails_only_after_settlement
    assistant = {
      "role" => "assistant",
      "content" => [],
      "stopReason" => "error",
      "errorMessage" => "provider unavailable",
      "timestamp" => 2
    }
    @session.send(:handle_jsonl_notification, { "type" => "agent_start" })
    @session.send(:handle_jsonl_notification, { "type" => "message_end", "message" => assistant })
    @session.send(:handle_jsonl_notification, {
      "type" => "agent_end", "messages" => [assistant], "willRetry" => false
    })

    refute events.any? { |row| row["type"] == "task_failed" }

    @session.send(:handle_jsonl_notification, { "type" => "agent_settled" })

    failure = events.reverse.find { |row| row["type"] == "task_failed" }
    assert_equal "error", failure.fetch("status")
    assert_equal "provider unavailable", failure.fetch("message")
    refute events.any? { |row| row["type"] == "task_complete" }
  end

  def test_aborted_and_length_stop_reasons_fail_closed
    %w[aborted length].each_with_index do |reason, index|
      assistant = {
        "role" => "assistant",
        "content" => [],
        "stopReason" => reason,
        "timestamp" => 10 + index
      }
      failures_before = events.count { |row| row["type"] == "task_failed" }
      @session.send(:handle_jsonl_notification, { "type" => "agent_start" })
      @session.send(:handle_jsonl_notification, {
        "type" => "agent_end", "messages" => [assistant], "willRetry" => false
      })
      assert_equal failures_before, events.count { |row| row["type"] == "task_failed" }

      @session.send(:handle_jsonl_notification, { "type" => "agent_settled" })
      failure = events.reverse.find { |row| row["type"] == "task_failed" }
      assert_equal reason, failure.fetch("status")
    end
  end

  def test_missing_final_stop_reason_fails_closed
    @session.send(:handle_jsonl_notification, { "type" => "agent_start" })
    @session.send(:handle_jsonl_notification, {
      "type" => "agent_end", "messages" => [], "willRetry" => false
    })
    @session.send(:handle_jsonl_notification, { "type" => "agent_settled" })

    failure = events.reverse.find { |row| row["type"] == "task_failed" }
    assert_equal "missing_final_message", failure.fetch("status")
    assert_includes failure.fetch("message"), "authoritative final assistant"
  end

  def test_retrying_agent_end_stays_busy_until_agent_settled
    assistant = {
      "role" => "assistant", "content" => [], "stopReason" => "error",
      "errorMessage" => "temporary overload", "timestamp" => 3
    }
    @session.send(:handle_jsonl_notification, { "type" => "agent_start" })
    @session.send(:handle_jsonl_notification, {
      "type" => "agent_end", "messages" => [assistant], "willRetry" => true
    })

    assert_equal "busy", @session.status_payload.fetch(:agent_state)
    refute events.any? { |row| %w[task_complete task_failed].include?(row["type"]) }
  end

  def test_auto_retry_emits_attempt_retry_scheduled_without_creating_a_new_attempt
    @session.send(:handle_jsonl_notification, {
      "type" => "auto_retry_start",
      "reason" => "transient_error"
    })

    retry_event, attempt_event = events.last(2)
    assert_equal "auto_retry_start", retry_event.fetch("type")
    assert_equal "attempt_retry_scheduled", attempt_event.fetch("type")
    assert_equal @session.session_id, attempt_event.fetch("attempt_id")
    assert_equal "adapter_auto_retry", attempt_event.fetch("trigger")
    assert_equal 1, @session.instance_variable_get(:@event_counters).snapshot.fetch(:retries)
  end

  def test_extension_ui_request_auto_cancels_dialog
    captured = nil
    @adapter.define_singleton_method(:respond_extension_ui_cancel) do |request_id:, method:|
      captured = [request_id, method]
      true
    end

    @session.send(:handle_jsonl_notification, {
      "type" => "extension_ui_request",
      "id" => "ui-1",
      "method" => "confirm",
      "title" => "Allow?"
    })

    assert_equal ["ui-1", "confirm"], captured
    row = events.last
    assert_equal "extension_ui_request", row["type"]
    assert_equal true, row["auto_cancelled"]
  end

  def test_run_with_initial_context_auto_stop_and_stats
    adapter = Harnex::Adapters::Pi.new(["--model", "anthropic/claude-sonnet-4-5", "[harnex session id=cx-i-44] implement feature"])
    session = Harnex::Session.new(
      adapter: adapter,
      command: adapter.build_command,
      repo_root: @tmp,
      host: "127.0.0.1",
      id: "pi-run",
      auto_stop: true,
      meta: {
        "model" => "anthropic/claude-sonnet-4-5",
        "effort" => "high"
      }
    )

    server_in, client_out = IO.pipe
    client_in, server_out = IO.pipe
    prompt_messages = Queue.new
    rpc_commands = Queue.new

    original_start = adapter.method(:start_rpc)
    adapter.define_singleton_method(:start_rpc) do |env: nil, cwd: nil|
      original_start.call(env: env, cwd: cwd, read_io: client_in, write_io: client_out, pid: nil)
    end

    server = Thread.new do
      loop do
        line = server_in.gets
        break unless line

        command = JSON.parse(line)
        rpc_commands << command["type"]
        case command["type"]
        when "get_state"
          response = {
            "type" => "response",
            "command" => "get_state",
            "success" => true,
            "data" => {
              "isStreaming" => false,
              "thinkingLevel" => "high",
              "model" => { "provider" => "anthropic", "id" => "claude-sonnet-4-5" },
              "sessionId" => "pi-session-44"
            }
          }
          response["id"] = command["id"] if command.key?("id")
          server_out.write(JSON.generate(response) + "\n")
        when "set_model"
          server_out.write(JSON.generate({
            "type" => "response",
            "id" => command["id"],
            "command" => "set_model",
            "success" => true,
            "data" => { "provider" => command["provider"], "id" => command["modelId"] }
          }) + "\n")
        when "set_thinking_level"
          server_out.write(JSON.generate({
            "type" => "response",
            "id" => command["id"],
            "command" => "set_thinking_level",
            "success" => true
          }) + "\n")
        when "prompt"
          prompt_messages << command["message"]
          server_out.write(JSON.generate({
            "type" => "response",
            "id" => command["id"],
            "command" => "prompt",
            "success" => true
          }) + "\n")
          assistant = {
            "role" => "assistant",
            "content" => [{ "type" => "text", "text" => "done" }],
            "stopReason" => "stop",
            "provider" => "anthropic",
            "model" => "claude-sonnet-4-5",
            "timestamp" => 1
          }
          server_out.write(JSON.generate({ "type" => "agent_start" }) + "\n")
          server_out.write(JSON.generate({
            "type" => "message_start",
            "message" => assistant.merge("content" => [])
          }) + "\n")
          server_out.write(JSON.generate({
            "type" => "message_update",
            "assistantMessageEvent" => { "type" => "text_delta", "contentIndex" => 0, "delta" => "done" }
          }) + "\n")
          server_out.write(JSON.generate({ "type" => "message_end", "message" => assistant }) + "\n")
          server_out.write(JSON.generate({
            "type" => "agent_end", "messages" => [assistant], "willRetry" => false
          }) + "\n")
          server_out.write(JSON.generate({ "type" => "agent_settled" }) + "\n")
        when "get_session_stats"
          response = {
            "type" => "response",
            "command" => "get_session_stats",
            "success" => true,
            "data" => {
              "sessionId" => "pi-session-44",
              "toolCalls" => 3,
              "tokens" => { "input" => 20, "output" => 8, "cacheRead" => 4, "total" => 28 },
              "cost" => 0.07,
              "contextUsage" => {
                "tokens" => 64_000,
                "contextWindow" => 200_000,
                "percent" => 32
              }
            }
          }
          response["id"] = command["id"] if command.key?("id")
          server_out.write(JSON.generate(response) + "\n")
        when "abort"
          server_out.write(JSON.generate({
            "type" => "response",
            "id" => command["id"],
            "command" => "abort",
            "success" => true
          }) + "\n")
          break
        end
        server_out.flush
      end
    rescue IOError, Errno::EPIPE
      nil
    ensure
      server_out.close unless server_out.closed?
    end

    assert_equal 0, session.run(validate_binary: false)
    assert_equal "[harnex session id=cx-i-44] implement feature", prompt_messages.pop
    assert_equal [
      "--model", "anthropic/claude-sonnet-4-5", "--thinking", "high"
    ], session.command.last(4)
    observed_commands = []
    observed_commands << rpc_commands.pop until rpc_commands.empty?
    refute_includes observed_commands, "set_model"
    refute_includes observed_commands, "set_thinking_level"

    record = JSON.parse(File.read(Harnex::DispatchHistory.path_for(@tmp)).lines.last)
    assert_equal "stdio_jsonl_rpc", record.dig("actual", "adapter_transport")
    assert_equal 0.07, record.dig("actual", "cost_usd")
    assert_equal "observed", record.dig("usage", "status")
    assert_equal "provider_reported", record.dig("usage", "cost_source")
    assert_equal 0.07, record.dig("usage", "cost_usd")
    assert_equal 3, record.dig("actual", "tool_calls")
    # No bash calls ran, so nothing went unobserved (#70).
    assert_equal "observed", record.dig("observed", "command_observation")
    assert_equal "not_run", record.dig("validation", "status")
    assert_equal "harnex", record.dig("receipt", "author")
    assert_equal "anthropic", record.dig("meta", "agent_provider")
    assert_equal "anthropic/claude-sonnet-4-5", record.dig("agent", "model_requested")
    assert_equal "claude-sonnet-4-5", record.dig("agent", "model_effective")
    assert_equal "high", record.dig("agent", "reasoning_effort")
    assert_equal "claude-sonnet-4-5", record.dig("actual", "model")
    assert_equal "observed", record.dig("context", "status")
    assert_equal "pi_get_session_stats", record.dig("context", "source")
    assert_equal 64_000, record.dig("context", "terminal_tokens")
    assert_equal 200_000, record.dig("context", "window_tokens")
    assert_equal 32.0, record.dig("context", "terminal_percent")
    assert_equal 64_000, record.dig("context", "peak_tokens")
    assert_equal 32.0, record.dig("context", "peak_percent")
  ensure
    server&.join(1)
    [server_out, client_out, client_in, server_in].each { |io| io.close unless io.closed? rescue nil }
  end

  def test_summary_record_includes_cost_and_usage_tool_calls
    @session.send(:emit_started_event)
    @session.send(:emit_git_start_event)

    @session.define_singleton_method(:collect_session_summary) do
      {
        input_tokens: 12,
        output_tokens: 6,
        cached_tokens: 4,
        total_tokens: 18,
        tool_calls: 9,
        cost_usd: 0.33,
        model: "claude-sonnet-4-5",
        agent_provider: "anthropic",
        agent_session_id: "pi-session-xyz",
        context: {
          status: "observed",
          source: "pi_get_session_stats",
          terminal_tokens: 64_000,
          window_tokens: 200_000,
          terminal_percent: 32.0,
          peak_tokens: 118_000,
          peak_percent: 59.0,
          samples: 2,
          missing_samples: 1,
          latest_sample_status: "missing"
        }
      }
    end

    @session.instance_variable_set(:@exit_code, 0)
    @session.instance_variable_set(:@last_completed_at, Time.now)
    @session.send(:finalize_session!)

    record = JSON.parse(File.read(Harnex::DispatchHistory.path_for(@tmp)).lines.last)
    assert_equal 0.33, record.dig("actual", "cost_usd")
    assert_equal "observed", record.dig("usage", "status")
    assert_equal "provider_reported", record.dig("usage", "cost_source")
    assert_equal 9, record.dig("actual", "tool_calls")
    assert_equal "anthropic", record.dig("meta", "agent_provider")
    assert_equal "claude-sonnet-4-5", record.dig("actual", "model")
    assert_equal "observed", record.dig("context", "status")
    assert_equal 64_000, record.dig("context", "terminal_tokens")
    assert_equal 118_000, record.dig("context", "peak_tokens")
    assert_equal 2, record.dig("context", "samples")
    assert_equal 1, record.dig("context", "missing_samples")
    assert_equal "missing", record.dig("context", "latest_sample_status")
  end

  # --- #70: Pi bash command/exit observation ---

  def pi_tool_start(call_id, name, args)
    @session.send(:handle_jsonl_notification, {
      "type" => "tool_execution_start", "toolCallId" => call_id, "toolName" => name, "args" => args
    })
  end

  # Mirrors Pi 1.3.0 bash results: exit evidence lives in
  # result.structuredContent, alongside output Harnex must not persist.
  def pi_tool_end(call_id, name, exit_code: nil, is_error: false, structured: true, duration_ms: 12)
    result = { "content" => [{ "type" => "text", "text" => "SECRET-OUTPUT" }] }
    if structured
      result["structuredContent"] = {
        "output" => "SECRET-OUTPUT", "truncated" => false, "exit_code" => exit_code, "wall_time_seconds" => 0
      }
    end
    message = {
      "type" => "tool_execution_end", "toolCallId" => call_id, "toolName" => name,
      "result" => result, "isError" => is_error
    }
    message["durationMs"] = duration_ms if duration_ms
    @session.send(:handle_jsonl_notification, message)
  end

  def finalized_record
    @session.send(:emit_started_event)
    @session.send(:emit_git_start_event)
    @session.instance_variable_set(:@exit_code, 0)
    @session.instance_variable_set(:@last_completed_at, Time.now)
    @session.send(:finalize_session!)
    JSON.parse(File.read(Harnex::DispatchHistory.path_for(@tmp)).lines.last)
  end

  # --- #68: final gates against harness-observed exits ---

  def use_final_gates(gates)
    @session = Harnex::Session.new(
      adapter: @adapter, command: ["pi", "--mode", "rpc"], repo_root: @tmp,
      host: "127.0.0.1", id: "pi-jsonl", meta: { "final_gates" => gates }
    )
    @session.send(:prepare_output_log)
    @session.send(:prepare_events_log)
  end

  def pi_bash(call_id, command, exit_code)
    capture_io do
      pi_tool_start(call_id, "bash", { "command" => command })
      pi_tool_end(call_id, "bash", exit_code: exit_code, is_error: !exit_code.zero?)
    end
  end

  def test_final_gate_green_after_exploratory_and_intermediate_failures_validates_pass
    use_final_gates(["rake test"])
    pi_bash("c1", "rg -n absent missing/", 2)
    pi_bash("c2", "rake test", 1)
    pi_bash("c3", "rake test", 0)

    record = finalized_record

    assert_equal "pass", record.dig("validation", "status")
    assert_equal true, record.dig("validation", "commands_had_failures")
    assert_equal(
      { "status" => "pass", "declared" => 1, "observed_pass" => 1, "observed_fail" => 0, "missing" => 0 },
      record.dig("validation", "final_gates")
    )
    receipt = JSON.parse(File.read(@session.artifact_report_path))
    assert_equal [{ "cmd" => "rake test", "exit_code" => 0 }], receipt.dig("validation", "final_gates", "gates")
  end

  def test_final_gate_whose_last_run_fails_validates_fail
    use_final_gates(["rake test", "ruby -c lib/a.rb"])
    pi_bash("c1", "rake test", 0)
    pi_bash("c2", "ruby -c lib/a.rb", 0)
    pi_bash("c3", "ruby -c lib/a.rb", 1)

    record = finalized_record

    assert_equal "fail", record.dig("validation", "status")
    assert_equal 1, record.dig("validation", "final_gates", "observed_fail")
  end

  def test_failure_outside_the_retained_command_window_still_sets_history_flag
    use_final_gates(["make check"])
    pi_bash("early", "make broken", 2)
    Harnex::ArtifactReport::MAX_COMMANDS.times { |index| pi_bash("ok-#{index}", "true #{index}", 0) }
    pi_bash("gate", "make check", 0)

    record = finalized_record

    assert(record.dig("observed", "commands").all? { |entry| entry["exit_code"].zero? })
    assert_equal true, record.dig("validation", "commands_had_failures")
    assert_equal "pass", record.dig("validation", "status")
  end

  def test_without_final_gates_validation_keeps_any_failure_semantics
    pi_bash("c1", "false", 1)
    pi_bash("c2", "true", 0)

    record = finalized_record

    assert_equal "fail", record.dig("validation", "status")
    assert_equal "undeclared", record.dig("validation", "final_gates", "status")
    assert_equal true, record.dig("validation", "commands_had_failures")
  end

  def test_pi_bash_success_and_failure_are_observed_with_integer_exits
    pi_tool_start("call_ok", "bash", { "command" => "ruby -c lib/a.rb", "timeout" => 10 })
    pi_tool_end("call_ok", "bash", exit_code: 0, duration_ms: 1500)
    pi_tool_start("call_bad", "bash", { "command" => "sh -c 'exit 3'" })
    pi_tool_end("call_bad", "bash", exit_code: 3, is_error: true)

    record = finalized_record

    assert_equal "observed", record.dig("observed", "command_observation")
    assert_equal [
      { "cmd" => "ruby -c lib/a.rb", "exit_code" => 0, "status" => "completed", "duration_s" => 1.5 },
      { "cmd" => "sh -c 'exit 3'", "exit_code" => 3, "status" => "failed", "duration_s" => 0.012 }
    ], record.dig("observed", "commands")
    assert_equal "fail", record.dig("validation", "status")
    assert_equal 2, record.dig("actual", "commands_executed")
    assert_equal 0, record.dig("actual", "tool_calls")
    refute_includes JSON.generate(record), "SECRET-OUTPUT"
    refute record["observed"].key?("commands_unobserved")
  end

  def test_pi_concurrent_bash_calls_correlate_by_tool_call_id
    pi_tool_start("call_a", "bash", { "command" => "make a" })
    pi_tool_start("call_b", "bash", { "command" => "make b" })
    pi_tool_end("call_b", "bash", exit_code: 2, is_error: true)
    pi_tool_end("call_a", "bash", exit_code: 0)

    commands = finalized_record.dig("observed", "commands")

    assert_equal({ "make b" => 2, "make a" => 0 }, commands.to_h { |entry| [entry["cmd"], entry["exit_code"]] })
  end

  def test_pi_non_bash_tools_stay_tool_calls_not_commands
    pi_tool_start("call_r", "read", { "path" => "README.md" })
    pi_tool_end("call_r", "read", structured: false)
    pi_tool_start("call_w", "write", { "path" => "a.txt", "content" => "x" })
    pi_tool_end("call_w", "write", structured: false)

    record = finalized_record

    assert_equal [], record.dig("observed", "commands")
    assert_equal "observed", record.dig("observed", "command_observation")
    assert_equal "not_run", record.dig("validation", "status")
    assert_equal 2, record.dig("actual", "tool_calls")
    assert_equal 0, record.dig("actual", "commands_executed")
  end

  def test_pi_bash_without_structured_exit_fails_closed_to_unsupported
    # Aborts and timeouts reach the RPC stream as plain error text with no
    # structuredContent; the prose "exited with code" must not be scraped.
    pi_tool_start("call_abort", "bash", { "command" => "sleep 999" })
    pi_tool_end("call_abort", "bash", structured: false, is_error: true)

    record = finalized_record

    assert_equal "unsupported", record.dig("observed", "command_observation")
    assert_equal 1, record.dig("observed", "commands_unobserved")
    assert_equal [], record.dig("observed", "commands")
    assert_equal "unknown", record.dig("validation", "status")
    assert_equal 1, record.dig("actual", "commands_executed")
  end

  def test_pi_malformed_or_uncorrelated_exits_make_observation_partial
    pi_tool_start("call_ok", "bash", { "command" => "true" })
    pi_tool_end("call_ok", "bash", exit_code: 0)
    pi_tool_start("call_str", "bash", { "command" => "echo string-exit" })
    pi_tool_end("call_str", "bash", exit_code: "0")
    pi_tool_start("call_float", "bash", { "command" => "echo float-exit" })
    pi_tool_end("call_float", "bash", exit_code: 0.0)
    pi_tool_end("call_orphan", "bash", exit_code: 0)
    pi_tool_start("call_noargs", "bash", nil)
    pi_tool_end("call_noargs", "bash", exit_code: 0)
    pi_tool_start("call_inflight", "bash", { "command" => "sleep 999" })

    record = finalized_record

    assert_equal "partial", record.dig("observed", "command_observation")
    assert_equal ["true"], record.dig("observed", "commands").map { |entry| entry["cmd"] }
    assert_equal 5, record.dig("observed", "commands_unobserved")
    assert_equal "unknown", record.dig("validation", "status")
  end

  def test_pi_bash_command_text_is_bounded
    long = "echo #{'x' * (Harnex::ArtifactReport::MAX_STRING_LENGTH * 3)}"
    pi_tool_start("call_long", "bash", { "command" => long })
    pi_tool_end("call_long", "bash", exit_code: 0)

    cmd = finalized_record.dig("observed", "commands", 0, "cmd")

    assert_equal Harnex::ArtifactReport::MAX_STRING_LENGTH, cmd.length
    assert long.start_with?(cmd)
  end
end
