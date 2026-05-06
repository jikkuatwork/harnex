require_relative "../../test_helper"
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
          server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: { "threadId" => "thr-session" } }) + "\n")
        when "turn/start"
          turn_requests << req
          server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: { "turnId" => "trn-session" } }) + "\n")
          server_out.write(JSON.generate({
            jsonrpc: "2.0",
            method: "turn/completed",
            params: { "turnId" => "trn-session", "status" => "completed" }
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
    fanout("thread/started", { "threadId" => "thr-a" })
    fanout("turn/started", { "turnId" => "trn-a" })
    fanout("turn/completed", { "turnId" => "trn-a", "status" => "completed" })

    types = events.map { |e| e["type"] }
    assert_includes types, "turn_started"
    assert_includes types, "task_complete"

    completed = events.find { |e| e["type"] == "task_complete" }
    assert_equal "trn-a", completed["turnId"]
    assert_equal "completed", completed["status"]
  end

  def test_item_completed_writes_synthesized_transcript_to_output_log
    text = "hello from codex"
    fanout("item/completed", { "item" => { "type" => "agent_message", "text" => text } })

    log = output
    assert_match(/hello from codex/, log)
    assert log.end_with?("\n"), "synthesized text should be newline-terminated"
  end

  def test_tool_call_renders_one_line_summary
    fanout("item/completed", { "item" => { "type" => "tool_call", "name" => "shell", "params" => { "cmd" => "ls" } } })
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

  def test_inject_via_jsonrpc_calls_dispatch
    server_in, client_out = IO.pipe
    client_in, server_out = IO.pipe

    server = Thread.new do
      req = JSON.parse(server_in.gets)
      server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: {} }) + "\n")
      server_out.flush
      server_in.gets # initialized notification
      req = JSON.parse(server_in.gets) # thread/start
      server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: { "threadId" => "thr-i" } }) + "\n")
      server_out.flush
      req = JSON.parse(server_in.gets) # turn/start
      server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: { "turnId" => "trn-i" } }) + "\n")
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
      request.dig("params", "input", "content", 0, "text")
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
    assert_equal "hello", request.dig("params", "input", "content", 0, "text")
  ensure
    close_stubbed_rpc(handles) if handles
  end
end
