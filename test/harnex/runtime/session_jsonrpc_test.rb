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

  def build_jsonrpc_session(adapter, id:)
    Harnex::Session.new(
      adapter: adapter,
      command: adapter.build_command,
      repo_root: @tmp,
      host: "127.0.0.1",
      id: id
    )
  end

  def test_turn_completed_emits_task_complete_event
    skip "Plan 29 Phase 5 fixes this — Session#handle_rpc_notification reads " \
         "params['turnId'] and params['status'] but the real schema is " \
         "params.turn.id and params.turn.status; with schema-shaped fanouts " \
         "the task_complete event ends up with turnId: nil and no status."

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
    skip "Plan 29 Phase 5 fixes this — Session#render_item_text matches the never-existed " \
         "snake_case 'tool_call' / 'agent_message' types; real Codex emits camelCase " \
         "schema types like 'mcpToolCall', 'commandExecution', 'agentMessage'."

    fanout("item/completed", Fixtures::Codex.item_completed_tool_call(tool: "shell"))
    assert_match(/tool: shell/, output)
  end

  def test_error_notification_emits_disconnected_event_and_counter
    fanout("error", { "message" => "stream broken" })

    types = events.map { |e| e["type"] }
    assert_includes types, "disconnected"

    counters = @session.instance_variable_get(:@event_counters).snapshot
    assert_equal 1, counters[:disconnections]
  end

  def test_thread_compacted_records_compaction_counter
    fanout("thread/compacted", {})
    counters = @session.instance_variable_get(:@event_counters).snapshot
    assert_equal 1, counters[:compactions]
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

  def test_classify_exit_keeps_late_pre_turn_exit_as_disconnected
    @session.instance_variable_set(:@exit_code, 0)
    @session.instance_variable_set(:@ended_at, @session.instance_variable_get(:@started_at) + 6)

    assert_equal "disconnected", @session.send(:classify_exit)
  end

  def test_inject_via_jsonrpc_calls_dispatch
    skip "Plan 29 Phase 5 fixes this — Adapter#dispatch reads result['turnId'] " \
         "but the real schema is result.turn.id; with schema-shaped stubs " \
         "Session#inject_via_adapter returns turn_id: nil until Phase 5 swaps " \
         "the parsing path."

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
