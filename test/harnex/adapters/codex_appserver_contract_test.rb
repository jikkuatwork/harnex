require_relative "../../test_helper"
require_relative "../../support/json_schema_validator"
require "json"

# Phase 3 of plan 29 — outgoing payload contract tests for the Codex
# `app-server` adapter.
#
# Boots the adapter against an IO.pipe-based fake server, captures
# every JSON line the app-server client emits, parses each one,
# and validates `params` (for outgoing client requests) or the result
# body (for auto-approval responses) against the matching schema
# fixture in test/fixtures/codex_schema/. Codex CLI fixture pin: 0.128.0.
class CodexAppServerContractTest < Minitest::Test
  Adapter = Harnex::Adapters::CodexAppServer
  Validator = JsonSchemaValidator
  SCHEMA_DIR = File.expand_path("../../fixtures/codex_schema", __dir__)

  def load_schema(rel_path)
    JSON.parse(File.read(File.join(SCHEMA_DIR, rel_path)))
  end

  def setup
    @server_in, @client_out = IO.pipe
    @client_in, @server_out = IO.pipe
    @adapter = Adapter.new
    @captured = []
    @captured_mutex = Mutex.new
    @server_thread = nil
  end

  def teardown
    # Close pipes first so the app-server client reader thread sees EOF
    # and the adapter's #close doesn't block on its 2s join timeout.
    [@server_in, @client_out, @client_in, @server_out].each do |io|
      io.close unless io.closed?
    rescue StandardError
      nil
    end
    begin
      @adapter.close
    rescue StandardError
      nil
    end
    @server_thread&.join(0.5)
    @server_thread&.kill if @server_thread&.alive?
  end

  # Server-side script: a queue of [method, response] pairs for
  # client-initiated requests. response may be a Hash (sent as JSON-RPC
  # `result`) or a Proc that receives the parsed request and returns a
  # serialized line. Server-initiated requests/notifications go through
  # push_request / push_notification. Every parsed message received
  # from the client is appended to @captured for later inspection.
  def start_server(rules)
    pending = rules.dup
    @server_thread = Thread.new do
      loop do
        line = @server_in.gets
        break if line.nil?
        message = JSON.parse(line)
        @captured_mutex.synchronize { @captured << message }

        # Only client-initiated requests get a stubbed response.
        next unless message["id"] && message["method"]

        rule = pending.shift
        unless rule && rule.first == message["method"]
          @server_out.write(JSON.generate({
            jsonrpc: "2.0", id: message["id"],
            error: { code: -32601, message: "unexpected #{message['method']}" }
          }) + "\n")
          @server_out.flush
          next
        end

        body = rule.last.is_a?(Proc) ? rule.last.call(message) : rule.last
        @server_out.write(JSON.generate({
          jsonrpc: "2.0", id: message["id"], result: body
        }) + "\n")
        @server_out.flush
      end
    rescue StandardError
      nil
    end
  end

  def push_request(id:, method:, params: {})
    @server_out.write(JSON.generate({
      jsonrpc: "2.0", id: id, method: method, params: params
    }) + "\n")
    @server_out.flush
  end

  def captured_snapshot
    @captured_mutex.synchronize { @captured.dup }
  end

  def find_request(method)
    captured_snapshot.find { |m| m["id"] && m["method"] == method }
  end

  def find_response_to(server_request_id)
    captured_snapshot.find { |m| !m["method"] && m["id"] == server_request_id }
  end

  def wait_for(timeout: 1.0)
    deadline = Time.now + timeout
    until yield
      return false if Time.now > deadline
      sleep 0.01
    end
    true
  end

  def assert_valid(schema, instance, label = "instance")
    errors = Validator.validate(schema, instance)
    assert_empty errors, "#{label} failed schema validation: #{errors.inspect}"
  end

  def boot(thread_id: "thr-1")
    start_server([
      ["initialize", {}],
      ["thread/start", { "thread" => { "id" => thread_id } }]
    ])
    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)
  end

  # ----- Case 1: initialize request (inline contract — no fixture) -----

  def test_initialize_request_clientinfo_and_capabilities_shape
    boot

    request = find_request("initialize")
    refute_nil request, "expected initialize request to be captured"

    params = request["params"]
    assert_kind_of Hash, params

    client_info = params["clientInfo"]
    assert_kind_of Hash, client_info
    assert_kind_of String, client_info["title"]
    assert_kind_of String, client_info["name"]
    assert_kind_of String, client_info["version"]
    refute client_info["title"].empty?
    refute client_info["version"].empty?

    capabilities = params["capabilities"]
    assert_kind_of Hash, capabilities
    assert_equal false, capabilities["experimentalApi"]
    assert_kind_of Array, capabilities["optOutNotificationMethods"]
    capabilities["optOutNotificationMethods"].each do |method|
      assert_kind_of String, method
    end
  end

  # ----- Case 2: thread/start params validate against schema -----
  # thread/start fires lazily on the first dispatch (via ensure_thread!),
  # not during the initialize handshake — so we trigger it explicitly.

  def test_thread_start_params_validate_against_schema
    start_server([
      ["initialize", {}],
      ["thread/start", { "thread" => { "id" => "thr-2" } }],
      ["turn/start", { "turnId" => "trn-2" }]
    ])
    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)
    @adapter.dispatch(prompt: "trigger thread/start")

    request = find_request("thread/start")
    refute_nil request, "expected thread/start request to be captured"

    schema = load_schema("v2/ThreadStartParams.json")
    assert_valid(schema, request["params"], "thread/start params")
  end

  # ----- Case 3: turn/start with prompt only -----

  def test_turn_start_params_with_prompt_only_validate_against_schema
    start_server([
      ["initialize", {}],
      ["thread/start", { "thread" => { "id" => "thr-3" } }],
      ["turn/start", { "turnId" => "trn-3" }]
    ])
    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)
    @adapter.dispatch(prompt: "hello")

    request = find_request("turn/start")
    refute_nil request, "expected turn/start request to be captured"

    schema = load_schema("v2/TurnStartParams.json")
    assert_valid(schema, request["params"], "turn/start params (prompt only)")
  end

  # ----- Case 4: turn/start with model + effort -----

  def test_turn_start_params_with_model_and_effort_validate_against_schema
    start_server([
      ["initialize", {}],
      ["thread/start", { "thread" => { "id" => "thr-4" } }],
      ["turn/start", { "turnId" => "trn-4" }]
    ])
    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)
    @adapter.dispatch(prompt: "hello", model: "gpt-5.5", effort: "high")

    request = find_request("turn/start")
    refute_nil request, "expected turn/start request to be captured"

    schema = load_schema("v2/TurnStartParams.json")
    assert_valid(schema, request["params"], "turn/start params (model + effort)")
    assert_equal "gpt-5.5", request.dig("params", "model")
    assert_equal "high", request.dig("params", "effort")
  end

  # ----- Case 5: turn/start from inbox-delivered harnex send -----
  # Exercises the end-to-end inject path (Inbox → Session →
  # Adapter#dispatch), not just the adapter, so that schema
  # regressions introduced by the session layer cannot ship silently.

  def test_turn_start_from_inbox_delivered_send_validates_against_schema
    Dir.mktmpdir("harnex-contract-inbox") do |tmp|
      adapter = Adapter.new
      session = Harnex::Session.new(
        adapter: adapter,
        command: ["codex", "app-server"],
        repo_root: tmp,
        host: "127.0.0.1",
        id: "test-contract-inbox"
      )

      server_in, client_out = IO.pipe
      client_in, server_out = IO.pipe
      turn_requests = Queue.new
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
              result: { "thread" => { "id" => "thr-5" } }
            }) + "\n")
          when "turn/start"
            turn_requests << req
            server_out.write(JSON.generate({
              jsonrpc: "2.0", id: req["id"], result: { "turnId" => "trn-5" }
            }) + "\n")
            server_out.write(JSON.generate({
              jsonrpc: "2.0", method: "turn/completed",
              params: { "turnId" => "trn-5", "status" => "completed" }
            }) + "\n")
          else
            server_out.write(JSON.generate({
              jsonrpc: "2.0", id: req["id"],
              error: { code: -32601, message: "unexpected #{req['method']}" }
            }) + "\n")
          end
          server_out.flush
        end
      rescue IOError, Errno::EPIPE
        nil
      end

      runner = Thread.new { session.run(validate_binary: false) }

      begin
        assert wait_for(timeout: 2.0) {
          session.status_payload(include_input_state: false)[:agent_state] == "prompt"
        }, "expected session to reach prompt state"

        result = session.inbox.enqueue(text: "hello", submit: true, enter_only: false)
        assert_equal true, result[:ok]

        assert wait_for(timeout: 2.0) { !turn_requests.empty? },
               "expected harnex send to dispatch a turn"
        request = turn_requests.pop

        schema = load_schema("v2/TurnStartParams.json")
        assert_valid(schema, request["params"], "inbox-driven turn/start params")
      ensure
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
    end
  end

  # ----- Case 6: turn/interrupt (inline contract — no fixture) -----

  def test_turn_interrupt_params_shape
    start_server([
      ["initialize", {}],
      ["thread/start", { "thread" => { "id" => "thr-6" } }],
      ["turn/start", { "turn" => { "id" => "trn-6" } }],
      ["turn/interrupt", {}]
    ])
    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)
    @adapter.dispatch(prompt: "long task")
    @adapter.interrupt

    request = find_request("turn/interrupt")
    refute_nil request, "expected turn/interrupt request to be captured"

    params = request["params"]
    assert_kind_of Hash, params
    assert_kind_of String, params["threadId"]
    assert_kind_of String, params["turnId"]
    refute_empty params["threadId"]
    refute_empty params["turnId"]
  end

  # ----- Case 7: auto-approval response bodies -----
  # Server pushes an approval request; harnex's
  # `Harnex::Codex::AppServer::Client#handle_server_request` dispatches to
  # `Adapters::CodexAppServer#handle_server_request`, which returns the
  # response body from APPROVAL_RESPONSES. The client writes it as a
  # JSON-RPC result. We capture and validate.

  def test_apply_patch_approval_response_validates_against_schema
    boot
    push_request(id: 100, method: "applyPatchApproval", params: { "patch" => "diff" })

    assert wait_for { find_response_to(100) },
           "expected client to respond to applyPatchApproval"
    response = find_response_to(100)
    schema = load_schema("ApplyPatchApprovalResponse.json")
    assert_valid(schema, response["result"], "applyPatchApproval response body")
  end

  def test_exec_command_approval_response_validates_against_schema
    boot
    push_request(id: 101, method: "execCommandApproval", params: { "command" => ["ls"] })

    assert wait_for { find_response_to(101) },
           "expected client to respond to execCommandApproval"
    response = find_response_to(101)
    schema = load_schema("ExecCommandApprovalResponse.json")
    assert_valid(schema, response["result"], "execCommandApproval response body")
  end

  def test_file_change_request_approval_response_validates_against_schema
    boot
    push_request(id: 102, method: "item/fileChange/requestApproval", params: {})

    assert wait_for { find_response_to(102) },
           "expected client to respond to item/fileChange/requestApproval"
    response = find_response_to(102)
    schema = load_schema("FileChangeRequestApprovalResponse.json")
    assert_valid(schema, response["result"], "fileChange approval response body")
  end

  def test_command_execution_request_approval_response_validates_against_schema
    boot
    push_request(id: 103, method: "item/commandExecution/requestApproval", params: {})

    assert wait_for { find_response_to(103) },
           "expected client to respond to item/commandExecution/requestApproval"
    response = find_response_to(103)
    schema = load_schema("CommandExecutionRequestApprovalResponse.json")
    assert_valid(schema, response["result"], "commandExecution approval response body")
  end
end
