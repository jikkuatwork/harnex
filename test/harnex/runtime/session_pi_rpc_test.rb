require_relative "../../test_helper"
require "json"

class SessionPiRpcTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("harnex-pi-session")
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

  def test_message_delta_and_agent_end_emit_task_complete
    @session.send(:handle_jsonl_notification, {
      "type" => "message_start",
      "message" => { "id" => "msg-1", "content" => [] }
    })
    @session.send(:handle_jsonl_notification, {
      "type" => "message_update",
      "message" => { "id" => "msg-1", "content" => [] },
      "assistantMessageEvent" => { "type" => "text_delta", "delta" => "Hello from pi" }
    })
    @session.send(:handle_jsonl_notification, { "type" => "agent_end" })

    assert_includes output, "Hello from pi"
    assert events.any? { |row| row["type"] == "task_complete" }
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
    summary_path = File.join(@tmp, "pi-dispatch.jsonl")
    session = Harnex::Session.new(
      adapter: adapter,
      command: adapter.build_command,
      repo_root: @tmp,
      host: "127.0.0.1",
      id: "pi-run",
      summary_out: summary_path,
      auto_stop: true
    )

    server_in, client_out = IO.pipe
    client_in, server_out = IO.pipe
    prompt_messages = Queue.new

    original_start = adapter.method(:start_rpc)
    adapter.define_singleton_method(:start_rpc) do |env: nil, cwd: nil|
      original_start.call(env: env, cwd: cwd, read_io: client_in, write_io: client_out, pid: nil)
    end

    server = Thread.new do
      loop do
        line = server_in.gets
        break unless line

        command = JSON.parse(line)
        case command["type"]
        when "get_state"
          response = {
            "type" => "response",
            "command" => "get_state",
            "success" => true,
            "data" => {
              "isStreaming" => false,
              "model" => { "provider" => "anthropic", "id" => "claude-sonnet-4-5" },
              "sessionId" => "pi-session-44"
            }
          }
          response["id"] = command["id"] if command.key?("id")
          server_out.write(JSON.generate(response) + "\n")
        when "prompt"
          prompt_messages << command["message"]
          server_out.write(JSON.generate({
            "type" => "response",
            "id" => command["id"],
            "command" => "prompt",
            "success" => true
          }) + "\n")
          server_out.write(JSON.generate({ "type" => "agent_start" }) + "\n")
          server_out.write(JSON.generate({
            "type" => "message_update",
            "message" => { "id" => "m1", "content" => [] },
            "assistantMessageEvent" => { "type" => "text_delta", "delta" => "done" }
          }) + "\n")
          server_out.write(JSON.generate({ "type" => "agent_end" }) + "\n")
        when "get_session_stats"
          response = {
            "type" => "response",
            "command" => "get_session_stats",
            "success" => true,
            "data" => {
              "sessionId" => "pi-session-44",
              "toolCalls" => 3,
              "tokens" => { "input" => 20, "output" => 8, "cacheRead" => 4, "total" => 28 },
              "cost" => 0.07
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

    record = JSON.parse(File.read(summary_path).lines.last)
    assert_equal "stdio_jsonl_rpc", record.dig("actual", "adapter_transport")
    assert_equal 0.07, record.dig("actual", "cost_usd")
    assert_equal "observed", record.dig("usage", "status")
    assert_equal "provider_reported", record.dig("usage", "cost_source")
    assert_equal 0.07, record.dig("usage", "cost_usd")
    assert_equal 3, record.dig("actual", "tool_calls")
    assert_equal "anthropic", record.dig("meta", "agent_provider")
    assert_equal "claude-sonnet-4-5", record.dig("actual", "model")
  ensure
    server&.join(1)
    [server_out, client_out, client_in, server_in].each { |io| io.close unless io.closed? rescue nil }
  end

  def test_summary_record_includes_cost_and_usage_tool_calls
    summary_path = File.join(@tmp, "DISPATCH.jsonl")
    @session.instance_variable_set(:@summary_out, summary_path)
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
        agent_session_id: "pi-session-xyz"
      }
    end

    @session.instance_variable_set(:@exit_code, 0)
    @session.instance_variable_set(:@last_completed_at, Time.now)
    @session.send(:finalize_session!)

    record = JSON.parse(File.read(summary_path).lines.last)
    assert_equal 0.33, record.dig("actual", "cost_usd")
    assert_equal "observed", record.dig("usage", "status")
    assert_equal "provider_reported", record.dig("usage", "cost_source")
    assert_equal 9, record.dig("actual", "tool_calls")
    assert_equal "anthropic", record.dig("meta", "agent_provider")
    assert_equal "claude-sonnet-4-5", record.dig("actual", "model")
  end
end
