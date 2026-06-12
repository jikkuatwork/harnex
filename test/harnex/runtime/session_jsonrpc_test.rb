require_relative "../../test_helper"
require_relative "../../support/codex_response_fixtures"
require "json"

class SessionJsonrpcTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("harnex-jsonrpc-test")
    @adapter = Harnex::Adapters::CodexAppServer.new
    @session = Harnex::Session.new(
      adapter: @adapter,
      command: ["codex", "app-server"],
      repo_root: @tmp,
      host: "127.0.0.1",
      id: "test-jsonrpc"
    )
    @session.send(:prepare_output_log)
    @session.send(:prepare_events_log)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def fanout(method, params = {})
    @session.send(:handle_rpc_notification, { "method" => method, "params" => params })
  end

  def events
    File.readlines(@session.events_log_path).map { |l| JSON.parse(l) }
  end

  def output
    File.binread(@session.output_log_path)
  end

  def wait_for(timeout: 1.0)
    deadline = Time.now + timeout
    until yield
      return false if Time.now > deadline
      sleep 0.01
    end
    true
  end

  def start_session_with_stubbed_rpc(adapter:, session:, turn_requests:)
    server_in, client_out = IO.pipe
    client_in, server_out = IO.pipe
    original_start = adapter.method(:start_rpc)

    adapter.define_singleton_method(:start_rpc) do |env: nil, cwd: nil|
      original_start.call(env: env, cwd: cwd, read_io: client_in, write_io: client_out, pid: nil)
    end

    server = Thread.new do
      loop do
        readable = IO.select([server_in], nil, nil, 2.0)
        break unless readable

        line = server_in.gets
        break unless line

        req = JSON.parse(line)
        next unless req["id"]

        case req["method"]
        when "initialize"
          server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: {} }) + "\n")
        when "thread/start"
          server_out.write(JSON.generate({
            jsonrpc: "2.0", id: req["id"],
            result: Fixtures::Codex.thread_start_response(id: "thr-session")
          }) + "\n")
        when "turn/start"
          turn_requests << req
          server_out.write(JSON.generate({
            jsonrpc: "2.0", id: req["id"],
            result: Fixtures::Codex.turn_start_response(id: "trn-session")
          }) + "\n")
          server_out.write(JSON.generate({
            jsonrpc: "2.0",
            method: "turn/completed",
            params: Fixtures::Codex.turn_completed_notification(
              thread_id: "thr-session", turn_id: "trn-session", status: "completed"
            )
          }) + "\n")
        else
          server_out.write(JSON.generate({
            jsonrpc: "2.0",
            id: req["id"],
            error: { code: -32601, message: "unexpected #{req['method']}" }
          }) + "\n")
        end
        server_out.flush
      end
    rescue IOError, Errno::EPIPE
      nil
    end

    runner = Thread.new { session.run(validate_binary: false) }

    [runner, server, server_in, client_out, client_in, server_out]
  end

  def close_stubbed_rpc(handles)
    runner, server, server_in, client_out, client_in, server_out = handles
    [server_out, client_out, client_in, server_in].each do |io|
      io.close unless io.closed?
    rescue StandardError
      nil
    end
    runner&.join(2)
    runner&.kill if runner&.alive?
    server&.join(1)
    server&.kill if server&.alive?
  end

  def build_jsonrpc_session(adapter, id:, summary_out: nil)
    Harnex::Session.new(
      adapter: adapter,
      command: adapter.build_command,
      repo_root: @tmp,
      host: "127.0.0.1",
      id: id,
      summary_out: summary_out
    )
  end

  def test_turn_completed_emits_task_complete_event
    fanout("thread/started", Fixtures::Codex.thread_started_notification(thread_id: "thr-a"))
    fanout("turn/started", Fixtures::Codex.turn_started_notification(thread_id: "thr-a", turn_id: "trn-a"))
    fanout("turn/completed",
      Fixtures::Codex.turn_completed_notification(thread_id: "thr-a", turn_id: "trn-a", status: "completed"))

    types = events.map { |e| e["type"] }
    assert_includes types, "turn_started"
    assert_includes types, "task_complete"

    completed = events.find { |e| e["type"] == "task_complete" }
    assert_equal "trn-a", completed["turnId"]
    assert_equal "completed", completed["status"]
  end

  def test_item_completed_writes_synthesized_transcript_to_output_log
    text = "hello from codex"
    fanout("item/completed", Fixtures::Codex.item_completed_agent_message(text: text))

    log = output
    assert_match(/hello from codex/, log)
    assert log.end_with?("\n"), "synthesized text should be newline-terminated"
  end

  def test_tool_call_renders_one_line_summary
    fanout("item/completed", Fixtures::Codex.item_completed_tool_call(tool: "shell"))
    assert_match(/tool: shell/, output)
  end

  def test_error_notification_emits_error_event_without_disconnect_counter
    fanout("error", {
      "error" => { "message" => "stream broken", "codexErrorInfo" => "other" },
      "willRetry" => false,
      "threadId" => "thr-e",
      "turnId" => "trn-e"
    })

    rows = events
    error = rows.find { |e| e["type"] == "error" }
    refute_nil error
    assert_equal "stream broken", error["message"]
    assert_equal "other", error["codex_error_info"]
    assert_equal false, error["will_retry"]

    counters = @session.instance_variable_get(:@event_counters).snapshot
    assert_equal 0, counters[:disconnections]
  end

  def test_thread_compacted_records_compaction_counter
    fanout("thread/compacted", {})
    counters = @session.instance_variable_get(:@event_counters).snapshot
    assert_equal 1, counters[:compactions]
  end

  def test_token_usage_notification_stores_cumulative_total
    notif = Fixtures::Codex.thread_token_usage_updated_notification(
      thread_id: "thr-tok",
      turn_id: "trn-tok",
      token_usage: Fixtures::Codex.thread_token_usage(
        total: Fixtures::Codex.token_usage_breakdown(
          input_tokens: 100, output_tokens: 25, cached_input_tokens: 80,
          reasoning_output_tokens: 10, total_tokens: 125
        )
      )
    )
    fanout("thread/tokenUsage/updated", notif)

    captured = @session.instance_variable_get(:@token_usage)
    assert_kind_of Hash, captured
    assert_equal 100, captured.dig("total", "inputTokens")
    assert_equal 25, captured.dig("total", "outputTokens")
    assert_equal 10, captured.dig("total", "reasoningOutputTokens")
    assert_equal 80, captured.dig("total", "cachedInputTokens")
  end

  def test_jsonrpc_session_writes_token_usage_to_dispatch_row
    summary_path = File.join(@tmp, "DISPATCH.jsonl")
    adapter = Harnex::Adapters::CodexAppServer.new
    session = build_jsonrpc_session(adapter, id: "tok-dispatch", summary_out: summary_path)
    session.send(:prepare_output_log)
    session.send(:prepare_events_log)
    session.send(:emit_started_event)
    session.send(:emit_git_start_event)
    session.send(:handle_rpc_notification, {
      "method" => "thread/started",
      "params" => Fixtures::Codex.thread_started_notification(thread_id: "thr-tok")
    })
    session.send(:handle_rpc_notification, {
      "method" => "turn/completed",
      "params" => Fixtures::Codex.turn_completed_notification(thread_id: "thr-tok", turn_id: "trn-tok")
    })

    notif = Fixtures::Codex.thread_token_usage_updated_notification(
      thread_id: "thr-tok",
      turn_id: "trn-tok",
      token_usage: Fixtures::Codex.thread_token_usage(
        total: Fixtures::Codex.token_usage_breakdown(
          input_tokens: 197_819, output_tokens: 25_018,
          cached_input_tokens: 6_408_576, reasoning_output_tokens: 12_501,
          total_tokens: 222_837
        )
      )
    )
    session.send(:handle_rpc_notification, { "method" => "thread/tokenUsage/updated", "params" => notif })
    session.instance_variable_set(:@exit_code, 0)
    session.send(:finalize_session!)

    record = JSON.parse(File.read(summary_path).lines.last)
    assert_equal 197_819, record.dig("actual", "input_tokens")
    assert_equal 25_018, record.dig("actual", "output_tokens")
    assert_equal 12_501, record.dig("actual", "reasoning_tokens")
    assert_equal 6_408_576, record.dig("actual", "cached_tokens")
    assert_equal 222_837, record.dig("actual", "total_tokens")
    assert_equal "thr-tok", record.dig("actual", "agent_session_id")
    assert_equal "stdio_jsonrpc", record.dig("actual", "adapter_transport")
    assert_equal true, record.dig("actual", "task_complete")
    assert_equal 0, record.dig("actual", "exit_code")
    assert_nil record.dig("actual", "signal")
    assert_nil record.dig("actual", "last_error")
  end

  def test_jsonrpc_session_with_no_token_usage_keeps_token_fields_null
    summary_path = File.join(@tmp, "DISPATCH.jsonl")
    adapter = Harnex::Adapters::CodexAppServer.new
    session = build_jsonrpc_session(adapter, id: "tok-empty", summary_out: summary_path)
    session.send(:prepare_output_log)
    session.send(:prepare_events_log)
    session.send(:emit_started_event)
    session.send(:emit_git_start_event)

    session.instance_variable_set(:@exit_code, 0)
    session.send(:finalize_session!)

    record = JSON.parse(File.read(summary_path).lines.last)
    assert_nil record.dig("actual", "input_tokens")
    assert_nil record.dig("actual", "output_tokens")
    assert_nil record.dig("actual", "reasoning_tokens")
    assert_nil record.dig("actual", "cached_tokens")
  end

  def test_classify_exit_marks_short_pre_turn_jsonrpc_exit_as_boot_failure
    @session.instance_variable_set(:@exit_code, nil)
    @session.instance_variable_set(:@ended_at, @session.instance_variable_get(:@started_at) + 1)

    assert_equal "boot_failure", @session.send(:classify_exit)
  end

  def test_classify_exit_keeps_post_turn_short_exit_as_disconnected
    fanout("turn/started",
      Fixtures::Codex.turn_started_notification(thread_id: "thr-boot", turn_id: "trn-boot"))
    @session.instance_variable_set(:@exit_code, 0)
    @session.instance_variable_set(:@ended_at, @session.instance_variable_get(:@started_at) + 1)

    assert_equal "disconnected", @session.send(:classify_exit)
  end

  def test_failed_turn_emits_task_failed_and_classifies_failure
    fanout("turn/started",
      Fixtures::Codex.turn_started_notification(thread_id: "thr-fail", turn_id: "trn-fail"))
    fanout("turn/completed", {
      "threadId" => "thr-fail",
      "turn" => {
        "id" => "trn-fail",
        "status" => "failed",
        "error" => { "message" => "Missing environment variable: `AZURE_OPENAI_API_KEY`.", "codexErrorInfo" => "other" }
      }
    })

    failed = events.find { |e| e["type"] == "task_failed" }
    refute_nil failed
    assert_equal "trn-fail", failed["turnId"]
    assert_equal "failed", failed["status"]
    assert_match(/AZURE_OPENAI_API_KEY/, failed["message"])

    payload = @session.status_payload(include_input_state: false)
    assert_equal false, payload[:task_complete]
    assert_equal true, payload[:task_failed]
    assert_equal false, payload[:done]
    assert_equal "failed", payload[:work_state]
    assert_match(/AZURE_OPENAI_API_KEY/, payload[:last_error])

    @session.instance_variable_set(:@exit_code, 0)
    @session.instance_variable_set(:@ended_at, @session.instance_variable_get(:@started_at) + 2)
    assert_equal "failure", @session.send(:classify_exit)
  end

  def test_classify_exit_keeps_late_pre_turn_exit_as_disconnected
    @session.instance_variable_set(:@exit_code, 0)
    @session.instance_variable_set(:@ended_at, @session.instance_variable_get(:@started_at) + 6)

    assert_equal "disconnected", @session.send(:classify_exit)
  end

  def test_inject_via_jsonrpc_calls_dispatch
    server_in, client_out = IO.pipe
    client_in, server_out = IO.pipe

    server = Thread.new do
      req = JSON.parse(server_in.gets)
      server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: {} }) + "\n")
      server_out.flush
      server_in.gets # initialized notification
      req = JSON.parse(server_in.gets) # thread/start
      server_out.write(JSON.generate({
        jsonrpc: "2.0", id: req["id"],
        result: Fixtures::Codex.thread_start_response(id: "thr-i")
      }) + "\n")
      server_out.flush
      req = JSON.parse(server_in.gets) # turn/start
      server_out.write(JSON.generate({
        jsonrpc: "2.0", id: req["id"],
        result: Fixtures::Codex.turn_start_response(id: "trn-i")
      }) + "\n")
      server_out.flush
    end

    @adapter.start_rpc(read_io: client_in, write_io: client_out, pid: nil)
    result = @session.inject_via_adapter(text: "do thing", submit: true, enter_only: false)

    assert result[:ok]
    assert_equal "trn-i", result[:turn_id]
    assert_equal "codex", result[:cli]

    types = events.map { |e| e["type"] }
    assert_includes types, "send"
  ensure
    server&.join(1)
    @adapter.close
    [server_in, client_out, client_in, server_out].each { |io| io.close rescue nil }
  end

  def test_jsonrpc_session_dispatches_initial_appserver_context
    adapter = Harnex::Adapters::CodexAppServer.new(["[harnex session id=ax-29-a] ok"])
    session = build_jsonrpc_session(adapter, id: "test-context")
    turn_requests = Queue.new
    handles = start_session_with_stubbed_rpc(adapter: adapter, session: session, turn_requests: turn_requests)

    assert wait_for { !turn_requests.empty? }, "expected initial context to dispatch a turn"
    request = turn_requests.pop

    assert_equal "turn/start", request["method"]
    assert_equal "thr-session", request.dig("params", "threadId")
    assert_equal "[harnex session id=ax-29-a] ok",
      request.dig("params", "input", 0, "text")
  ensure
    close_stubbed_rpc(handles) if handles
  end

  def test_jsonrpc_run_writes_boot_failure_summary_when_initial_turn_errors
    adapter = Harnex::Adapters::CodexAppServer.new(["[harnex session id=boot-fail] echo OK"])
    summary_path = File.join(@tmp, "DISPATCH.jsonl")
    session = build_jsonrpc_session(adapter, id: "boot-fail", summary_out: summary_path)
    server_in, client_out = IO.pipe
    client_in, server_out = IO.pipe
    original_start = adapter.method(:start_rpc)

    adapter.define_singleton_method(:start_rpc) do |env: nil, cwd: nil|
      original_start.call(env: env, cwd: cwd, read_io: client_in, write_io: client_out, pid: nil)
    end

    server = Thread.new do
      req = JSON.parse(server_in.gets)
      server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: {} }) + "\n")
      server_out.flush
      server_in.gets # initialized notification

      req = JSON.parse(server_in.gets)
      server_out.write(JSON.generate({
        jsonrpc: "2.0",
        id: req["id"],
        result: Fixtures::Codex.thread_start_response(id: "thr-boot-fail")
      }) + "\n")
      server_out.flush

      req = JSON.parse(server_in.gets)
      server_out.write(JSON.generate({
        jsonrpc: "2.0",
        id: req["id"],
        error: {
          code: -32_000,
          message: "Invalid request: invalid type: null, expected a string"
        }
      }) + "\n")
      server_out.flush
    rescue IOError, Errno::EPIPE
      nil
    end

    err = assert_raises(StandardError) { session.run(validate_binary: false) }
    assert_match(/Invalid request: invalid type: null/, err.message)

    rows = File.readlines(session.events_log_path).map { |line| JSON.parse(line) }
    assert_equal %w[started task_failed usage summary exited], rows.map { |row| row["type"] }
    assert_equal "boot_failure", rows[-2]["exit"]
    assert_equal "boot_failure", rows[-1]["reason"]

    record = JSON.parse(File.read(summary_path).lines.last)
    assert_equal "boot-fail", record.dig("meta", "id")
    assert_kind_of String, record.dig("meta", "started_at")
    assert_kind_of String, record.dig("meta", "ended_at")
    assert_equal "boot_failure", record.dig("actual", "exit")
    assert_equal 1, record.dig("actual", "disconnections")
    assert_operator record.dig("actual", "duration_s"), :<=, 5
    assert_equal(
      "Invalid request: invalid type: null, expected a string",
      record.dig("actual", "last_error")
    )
  ensure
    server&.join(1)
    [server_out, client_out, client_in, server_in].each do |io|
      io.close unless io.closed?
    rescue StandardError
      nil
    end
  end

  def test_jsonrpc_inbox_delivers_harnex_send_when_prompt
    adapter = Harnex::Adapters::CodexAppServer.new
    session = build_jsonrpc_session(adapter, id: "test-send")
    turn_requests = Queue.new
    handles = start_session_with_stubbed_rpc(adapter: adapter, session: session, turn_requests: turn_requests)

    assert wait_for { session.status_payload(include_input_state: false)[:agent_state] == "prompt" },
      "expected JSON-RPC session state machine to become prompt"

    result = session.inbox.enqueue(text: "hello", submit: true, enter_only: false)

    assert_equal true, result[:ok]
    assert_equal "delivered", result[:status]
    assert wait_for { !turn_requests.empty? }, "expected harnex send to dispatch a turn"

    request = turn_requests.pop
    assert_equal "turn/start", request["method"]
    assert_equal "hello", request.dig("params", "input", 0, "text")
  ensure
    close_stubbed_rpc(handles) if handles
  end
end
