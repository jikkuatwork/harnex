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
    assert_equal "unsupported", record.dig("observed", "command_observation")
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
end
