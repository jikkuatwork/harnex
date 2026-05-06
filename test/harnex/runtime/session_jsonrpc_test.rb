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
end
