require_relative "../../test_helper"
require "json"

class CodexAppServerLifecycleTest < Minitest::Test
  Adapter = Harnex::Adapters::CodexAppServer

  def setup
    @server_in, @client_out = IO.pipe
    @client_in, @server_out = IO.pipe
    @adapter = Adapter.new
    @notifications = []
    @adapter.on_notification { |n| @notifications << n }
  end

  def teardown
    [@server_in, @client_out, @client_in, @server_out].each do |io|
      io.close unless io.closed?
    rescue StandardError
      nil
    end
  end

  # Server stub that scripts responses to a queue of (method, response) rules.
  # Notifications written via `push_notification` interleave naturally.
  def start_server(rules)
    Thread.new do
      pending = rules.dup
      loop do
        line = @server_in.gets
        break if line.nil?
        req = JSON.parse(line)
        next unless req["id"] # ignore notifications

        rule = pending.shift
        break unless rule

        method, response = rule
        unless req["method"] == method
          @server_out.write(JSON.generate({
            jsonrpc: "2.0", id: req["id"],
            error: { code: -32601, message: "unexpected #{req['method']} (wanted #{method})" }
          }) + "\n")
          @server_out.flush
          next
        end

        if response.is_a?(Proc)
          out = response.call(req)
          @server_out.write(out)
        else
          @server_out.write(JSON.generate({
            jsonrpc: "2.0", id: req["id"], result: response
          }) + "\n")
        end
        @server_out.flush
      end
    rescue StandardError
      nil
    end
  end

  def push_notification(method, params = {})
    @server_out.write(JSON.generate({
      jsonrpc: "2.0", method: method, params: params
    }) + "\n")
    @server_out.flush
  end

  def wait_for(timeout: 1.0)
    deadline = Time.now + timeout
    until yield
      return false if Time.now > deadline
      sleep 0.01
    end
    true
  end

  def boot
    server = start_server([
      ["initialize", {}],
      ["thread/start", { "threadId" => "thr-1" }],
      ["turn/start", { "turnId" => "trn-1" }]
    ])
    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)
    server
  end

  # 1. Golden turn lifecycle
  def test_golden_turn_lifecycle
    boot
    turn_id = @adapter.dispatch(prompt: "hello", model: "gpt-5", effort: "medium")
    assert_equal "trn-1", turn_id
    assert_equal :busy, @adapter.state

    push_notification("turn/started", { "turnId" => "trn-1" })
    push_notification("item/completed", { "item" => { "type" => "agent_message", "text" => "hi" } })
    push_notification("item/completed", { "item" => { "type" => "tool_call", "name" => "shell" } })
    push_notification("turn/completed", { "turnId" => "trn-1", "status" => "completed" })

    assert wait_for { @notifications.size >= 4 }, "expected 4 notifications, got #{@notifications.size}"

    methods = @notifications.map { |n| n["method"] }
    assert_equal %w[turn/started item/completed item/completed turn/completed], methods
    assert_equal :prompt, @adapter.state
    refute_nil @adapter.last_completed_at
  end

  # 2. Interrupt mid-turn
  def test_interrupt_mid_turn
    server = Thread.new do
      # initialize
      req = JSON.parse(@server_in.gets)
      @server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: {} }) + "\n")
      @server_out.flush
      @server_in.gets # initialized notification
      # thread/start
      req = JSON.parse(@server_in.gets)
      @server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: { "threadId" => "thr-x" } }) + "\n")
      @server_out.flush
      # turn/start
      req = JSON.parse(@server_in.gets)
      @server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: { "turnId" => "trn-x" } }) + "\n")
      @server_out.flush
      # turn/interrupt
      req = JSON.parse(@server_in.gets)
      @server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: {} }) + "\n")
      @server_out.flush
    end

    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)
    @adapter.dispatch(prompt: "long task")
    push_notification("turn/started", { "turnId" => "trn-x" })

    assert wait_for { @notifications.any? { |n| n["method"] == "turn/started" } }

    @adapter.interrupt
    push_notification("turn/completed", { "turnId" => "trn-x", "status" => "interrupted" })

    assert wait_for { @notifications.any? { |n| n["method"] == "turn/completed" } }
    assert_equal :prompt, @adapter.state
    completed = @notifications.find { |n| n["method"] == "turn/completed" }
    assert_equal "interrupted", completed.dig("params", "status")
  ensure
    server&.join(1)
  end

  # 3. Disconnect via JSON-RPC error response (per P2-A — preferred path).
  # This is the brief's required adaptation: a JSON-RPC error keyed by
  # request id, NOT an `error` notification.
  def test_disconnect_via_jsonrpc_error_response
    server = Thread.new do
      req = JSON.parse(@server_in.gets)
      @server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: {} }) + "\n")
      @server_out.flush
      @server_in.gets
      req = JSON.parse(@server_in.gets) # thread/start
      @server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: { "threadId" => "thr-e" } }) + "\n")
      @server_out.flush
      req = JSON.parse(@server_in.gets) # turn/start — fail with error response
      @server_out.write(JSON.generate({
        jsonrpc: "2.0", id: req["id"],
        error: { code: -1, message: "model unavailable" }
      }) + "\n")
      @server_out.flush
    end

    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)

    err = assert_raises(StandardError) { @adapter.dispatch(prompt: "boom") }
    assert_match(/model unavailable/, err.message)

    assert wait_for { @adapter.state == :disconnected }
    assert_raises(RuntimeError) { @adapter.dispatch(prompt: "again") }
  ensure
    server&.join(1)
  end

  # Disconnect via `error` server notification (schema-defined path).
  def test_disconnect_via_error_notification
    boot
    push_notification("error", { "message" => "stream broken" })

    assert wait_for { @adapter.state == :disconnected }
    assert_raises(RuntimeError) { @adapter.dispatch(prompt: "x") }
  end

  # Disconnect via subprocess EOF (read loop exits; client signals disconnect).
  def test_disconnect_via_eof
    disconnects = 0
    @adapter.on_disconnect { disconnects += 1 }

    server = Thread.new do
      req = JSON.parse(@server_in.gets)
      @server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: {} }) + "\n")
      @server_out.flush
      @server_in.gets # initialized
      @server_out.close
    end

    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)
    server.join(1)

    assert wait_for { @adapter.state == :disconnected }
    assert_operator disconnects, :>=, 1
  end
end
