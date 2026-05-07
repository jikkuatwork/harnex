require_relative "../../test_helper"
require "json"

# Server→client approval handling: codex `app-server` sends approval
# requests via JSON-RPC when its sandbox/approval policy needs a client
# decision. Harnex acts as the IDE-mediator and auto-approves so
# dispatched workers can run autonomously.
class CodexAppServerApprovalsTest < Minitest::Test
  Adapter = Harnex::Adapters::CodexAppServer

  def setup
    @server_in, @client_out = IO.pipe
    @client_in, @server_out = IO.pipe
    @adapter = Adapter.new
  end

  def teardown
    [@server_in, @client_out, @client_in, @server_out].each do |io|
      io.close unless io.closed?
    rescue StandardError
      nil
    end
  end

  def consume_handshake
    init_line = @server_in.gets
    init = JSON.parse(init_line)
    @server_out.write(JSON.generate({ jsonrpc: "2.0", id: init["id"], result: {} }) + "\n")
    @server_out.flush
    @server_in.gets # consume initialized notification
  end

  def send_server_request(id:, method:, params: {})
    @server_out.write(JSON.generate({ jsonrpc: "2.0", id: id, method: method, params: params }) + "\n")
    @server_out.flush
  end

  def read_client_message
    JSON.parse(@server_in.gets)
  end

  def test_file_change_approval_responds_with_accept
    server_thread = Thread.new do
      consume_handshake
      send_server_request(
        id: 100,
        method: "item/fileChange/requestApproval",
        params: { "itemId" => "i1", "threadId" => "t1", "turnId" => "u1" }
      )
      read_client_message
    end

    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)
    response = server_thread.value

    assert_equal 100, response["id"]
    assert_nil response["error"]
    assert_equal "accept", response.dig("result", "decision")
  end

  def test_command_execution_approval_responds_with_accept
    server_thread = Thread.new do
      consume_handshake
      send_server_request(
        id: 101,
        method: "item/commandExecution/requestApproval",
        params: { "callId" => "c1", "command" => ["echo", "hi"], "conversationId" => "t1", "cwd" => "/", "parsedCmd" => [] }
      )
      read_client_message
    end

    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)
    response = server_thread.value

    assert_equal 101, response["id"]
    assert_equal "accept", response.dig("result", "decision")
  end

  def test_legacy_apply_patch_and_exec_command_approvals_respond_with_approved
    server_thread = Thread.new do
      consume_handshake
      send_server_request(id: 200, method: "applyPatchApproval")
      apply = read_client_message
      send_server_request(id: 201, method: "execCommandApproval")
      exec = read_client_message
      [apply, exec]
    end

    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)
    apply, exec = server_thread.value

    assert_equal "approved", apply.dig("result", "decision")
    assert_equal "approved", exec.dig("result", "decision")
  end

  def test_unknown_server_request_falls_through_to_method_not_found
    server_thread = Thread.new do
      consume_handshake
      send_server_request(id: 300, method: "some/unknown/method")
      read_client_message
    end

    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)
    response = server_thread.value

    assert_equal 300, response["id"]
    assert_nil response["result"]
    assert_equal(-32601, response.dig("error", "code"))
    assert_match(/Unsupported server request/, response.dig("error", "message"))
  end

  def test_permissions_and_user_input_requests_currently_unhandled
    # Documenting current behavior: only the four approval methods in
    # APPROVAL_RESPONSES auto-respond. Permissions/user-input/dynamic-tool
    # requests have richer response shapes and are deliberately rejected
    # with -32601 until a real use case appears.
    server_thread = Thread.new do
      consume_handshake
      send_server_request(id: 400, method: "item/permissions/requestApproval")
      perm = read_client_message
      send_server_request(id: 401, method: "item/tool/requestUserInput")
      tool = read_client_message
      [perm, tool]
    end

    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)
    perm, tool = server_thread.value

    assert_equal(-32601, perm.dig("error", "code"))
    assert_equal(-32601, tool.dig("error", "code"))
  end

  def test_handle_server_request_returns_nil_for_unknown_methods
    assert_nil @adapter.handle_server_request("some/unknown/method", {})
  end

  def test_handle_server_request_returns_response_body_for_known_methods
    assert_equal({ decision: "approved" },
      @adapter.handle_server_request("execCommandApproval", {}))
    assert_equal({ decision: "accept" },
      @adapter.handle_server_request("item/fileChange/requestApproval", {}))
  end
end

class CodexAppServerExtraArgsTest < Minitest::Test
  Adapter = Harnex::Adapters::CodexAppServer

  def test_build_command_appends_codex_flags_so_operators_can_tune_sandbox
    adapter = Adapter.new(["-c", "sandbox_mode=danger-full-access", "-c", "approval_policy=never"])
    assert_equal(
      ["codex", "app-server", "-c", "sandbox_mode=danger-full-access", "-c", "approval_policy=never"],
      adapter.build_command
    )
  end

  def test_build_command_with_no_extra_args_returns_just_base
    adapter = Adapter.new
    assert_equal ["codex", "app-server"], adapter.build_command
  end

  # The `--context` flag prepends a "[harnex session id=...] <prompt>"
  # entry into @extra_args. That entry is delivered via JSON-RPC
  # `turn/start`, not as a CLI argument — codex app-server rejects
  # positional input and would exit at startup.
  def test_build_command_strips_harnex_context_entry_but_keeps_codex_flags
    adapter = Adapter.new([
      "-c", "sandbox_mode=danger-full-access",
      "[harnex session id=cx-1] write a file"
    ])
    assert_equal(
      ["codex", "app-server", "-c", "sandbox_mode=danger-full-access"],
      adapter.build_command
    )
  end

  def test_build_command_strips_only_the_harnex_context_marker
    adapter = Adapter.new(["[harnex session id=cx-1] do work"])
    assert_equal ["codex", "app-server"], adapter.build_command
  end

  def test_initial_prompt_still_extracted_from_extra_args
    adapter = Adapter.new(["-c", "x=1", "[harnex session id=cx-1] do work"])
    assert_equal "[harnex session id=cx-1] do work", adapter.initial_prompt
  end
end

# `-m/--model` is a regular-codex flag that codex `app-server` does
# not implement. Without an early reject, the subprocess exits at
# startup and harnex surfaces only `disconnected source=transport
# message=null`, which is indistinguishable from a real schema bug.
# See koder/issues/34_appserver_flag_translation.md.
class CodexAppServerUnsupportedFlagsTest < Minitest::Test
  Adapter = Harnex::Adapters::CodexAppServer

  def test_short_m_flag_is_rejected_with_actionable_hint
    err = assert_raises(ArgumentError) { Adapter.new(["-m", "gpt-5.5"]) }
    assert_match(/not supported by `codex app-server`/, err.message)
    assert_match(/-c model=/, err.message)
  end

  def test_long_model_flag_is_rejected
    err = assert_raises(ArgumentError) { Adapter.new(["--model", "gpt-5.5"]) }
    assert_match(/not supported by `codex app-server`/, err.message)
  end

  def test_model_equals_form_is_rejected
    err = assert_raises(ArgumentError) { Adapter.new(["--model=gpt-5.5"]) }
    assert_match(/not supported by `codex app-server`/, err.message)
  end

  # Spec acceptance test: `harnex run codex ... -- -m gpt-5.5 2>&1
  # | grep -q "model.*not supported\|Use \`-c model"` must succeed.
  def test_error_message_satisfies_spec_grep
    err = assert_raises(ArgumentError) { Adapter.new(["-m", "x"]) }
    matches_first = err.message.match?(/model.*not supported/)
    matches_second = err.message.include?("Use `-c model")
    assert(matches_first || matches_second,
      "error message should match grep pattern: #{err.message.inspect}")
  end

  def test_c_model_form_is_accepted
    adapter = Adapter.new(["-c", "model=gpt-5.5"])
    assert_equal ["codex", "app-server", "-c", "model=gpt-5.5"], adapter.build_command
  end

  # Validator must not false-positive when `-m`/`--model` appears as a
  # substring of an unrelated argv element (e.g. inside a `-c` value).
  def test_substring_of_other_args_is_not_rejected
    adapter = Adapter.new(["-c", "some_key=-m something"])
    assert_equal ["codex", "app-server", "-c", "some_key=-m something"], adapter.build_command
  end

  # The legacy PTY adapter must still accept `-m`; the rejection is
  # specific to the JSON-RPC transport.
  def test_legacy_pty_adapter_still_accepts_m_flag
    adapter = Harnex::Adapters::Codex.new(["-m", "gpt-5.5"])
    assert_includes adapter.build_command, "-m"
    assert_includes adapter.build_command, "gpt-5.5"
  end
end
