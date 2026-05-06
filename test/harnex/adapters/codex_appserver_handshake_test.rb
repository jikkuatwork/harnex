require_relative "../../test_helper"
require "json"

class CodexAppServerHandshakeTest < Minitest::Test
  Adapter = Harnex::Adapters::CodexAppServer

  # Wires two pipes that mimic a child subprocess:
  #   - server_in / client_out: client writes here, "server" reads
  #   - client_in / server_out: client reads here, "server" writes
  def setup
    @server_in, @client_out = IO.pipe   # server reads what client wrote
    @client_in, @server_out = IO.pipe   # client reads what server wrote
    @adapter = Adapter.new
  end

  def teardown
    [@server_in, @client_out, @client_in, @server_out].each do |io|
      io.close unless io.closed?
    rescue StandardError
      nil
    end
  end

  def test_handshake_sends_initialize_then_initialized
    server_thread = Thread.new do
      # Read first request (initialize) and respond.
      init_line = @server_in.gets
      init = JSON.parse(init_line)
      @server_out.write(JSON.generate({ jsonrpc: "2.0", id: init["id"], result: {} }) + "\n")
      @server_out.flush
      # Read the initialized notification and stop.
      notif_line = @server_in.gets
      [init, JSON.parse(notif_line)]
    end

    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)

    init, notif = server_thread.value

    assert_equal "initialize", init["method"]
    assert_equal "2.0", init["jsonrpc"]
    assert_equal Harnex::VERSION, init.dig("params", "clientInfo", "version")
    assert_equal "harnex", init.dig("params", "clientInfo", "name")
    assert_equal false, init.dig("params", "capabilities", "experimentalApi")
    opt_outs = init.dig("params", "capabilities", "optOutNotificationMethods")
    assert_includes opt_outs, "item/agentMessage/delta"
    assert_includes opt_outs, "item/reasoning/textDelta"

    assert_equal "initialized", notif["method"]
    refute notif.key?("id"), "initialized must be a notification, not a request"

    assert_equal :prompt, @adapter.state
  end

  def test_close_joins_read_thread
    Thread.new do
      init_line = @server_in.gets
      init = JSON.parse(init_line)
      @server_out.write(JSON.generate({ jsonrpc: "2.0", id: init["id"], result: {} }) + "\n")
      @server_out.flush
      @server_in.gets # consume initialized
    end

    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)

    # Close the server side so reader hits EOF.
    @server_out.close
    @adapter.close

    assert_equal :disconnected, @adapter.state
  end

  def test_transport_advertises_stdio_jsonrpc
    assert_equal :stdio_jsonrpc, @adapter.transport
    description = @adapter.describe
    assert_equal :stdio_jsonrpc, description[:transport]
    assert_includes description[:request_methods], "initialize"
    assert_includes description[:notification_methods], "turn/completed"
  end

  def test_feature_flag_gates_default_codex_build
    ENV.delete("HARNEX_CODEX_APPSERVER")
    refute Harnex::Adapters.codex_appserver_enabled?
    assert_kind_of Harnex::Adapters::Codex, Harnex::Adapters.build("codex")

    ENV["HARNEX_CODEX_APPSERVER"] = "1"
    assert Harnex::Adapters.codex_appserver_enabled?
    assert_kind_of Harnex::Adapters::CodexAppServer, Harnex::Adapters.build("codex")
  ensure
    ENV.delete("HARNEX_CODEX_APPSERVER")
  end

  def test_legacy_pty_kwarg_forces_legacy_adapter
    ENV["HARNEX_CODEX_APPSERVER"] = "1"
    assert_kind_of Harnex::Adapters::Codex,
      Harnex::Adapters.build("codex", [], legacy_pty: true)
  ensure
    ENV.delete("HARNEX_CODEX_APPSERVER")
  end

  def test_base_command_is_codex_app_server
    assert_equal ["codex", "app-server"], @adapter.base_command
  end

  def test_input_state_is_rpc_driven
    state = @adapter.input_state(nil)
    assert_equal "disconnected", state[:state]
    assert_equal false, state[:input_ready]
  end
end
