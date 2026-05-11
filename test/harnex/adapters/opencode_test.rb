require_relative "../../test_helper"

class OpencodeAdapterTest < Minitest::Test
  def setup
    @adapter = Harnex::Adapters::Opencode.new
  end

  def test_base_command
    assert_equal ["opencode"], @adapter.base_command
  end

  def test_provider_is_opencode
    assert_equal "opencode", @adapter.provider
  end

  def test_build_command_appends_extra_args
    adapter = Harnex::Adapters::Opencode.new(["--print-logs"])
    assert_equal(
      ["opencode", "--print-logs"],
      adapter.build_command
    )
  end

  def test_build_returns_opencode_adapter
    adapter = Harnex::Adapters.build("opencode", ["--print-logs"])
    assert_instance_of Harnex::Adapters::Opencode, adapter
    assert_equal(
      ["opencode", "--print-logs"],
      adapter.build_command
    )
  end

  def test_known_adapters_include_opencode
    assert_includes Harnex::Adapters.known, "opencode"
  end

  def test_infer_repo_path_prefers_dir_flag
    assert_equal "/tmp/repo", @adapter.infer_repo_path(["--dir", "/tmp/repo"])
  end

  def test_infer_repo_path_supports_dir_equals_form
    assert_equal "/tmp/repo", @adapter.infer_repo_path(["--dir=/tmp/repo"])
  end

  def test_infer_repo_path_falls_back_to_positional_project_path
    assert_equal "/tmp/repo", @adapter.infer_repo_path(["/tmp/repo", "--print-logs"])
  end

  def test_infer_repo_path_defaults_to_pwd
    assert_equal Dir.pwd, @adapter.infer_repo_path([])
  end

  def test_input_state_detects_continue_hint_as_prompt
    screen = "Session Greeting\nContinue opencode -s ses_abc123\n"
    state = @adapter.input_state(screen)
    assert_equal "prompt", state[:state]
    assert_equal true, state[:input_ready]
  end

  def test_input_state_detects_prompt_line
    state = @adapter.input_state("work\n> \n")
    assert_equal "prompt", state[:state]
    assert_equal true, state[:input_ready]
  end

  def test_input_state_returns_unknown_for_empty_output
    state = @adapter.input_state("")
    assert_equal "unknown", state[:state]
    assert_nil state[:input_ready]
  end

  def test_input_state_falls_back_to_prompt_once_screen_seen
    @adapter.input_state("\e[?25l\e[2J")
    state = @adapter.input_state("")
    assert_equal "prompt", state[:state]
    assert_equal true, state[:input_ready]
  end

  def test_parse_session_summary_extracts_session_id
    summary = @adapter.parse_session_summary("Continue opencode -s ses_1e86fe5d6ffei8n6NGadd7WzuI")
    assert_equal "ses_1e86fe5d6ffei8n6NGadd7WzuI", summary[:agent_session_id]
    assert_nil summary[:input_tokens]
    assert_nil summary[:output_tokens]
    assert_nil summary[:reasoning_tokens]
    assert_nil summary[:cached_tokens]
    assert_nil summary[:total_tokens]
  end

  def test_build_send_payload_splits_text_and_submit
    payload = @adapter.build_send_payload(
      text: "hello",
      submit: true,
      enter_only: false,
      screen_text: "OpenCode"
    )

    assert_equal 2, payload.fetch(:steps).length
    assert_equal "hello", payload.fetch(:steps)[0][:text]
    assert_equal "\r", payload.fetch(:steps)[1][:text]
    assert_operator payload.fetch(:steps)[1][:delay_ms], :>=, 75
  end

  def test_build_send_payload_submit_only
    payload = @adapter.build_send_payload(
      text: "",
      submit: true,
      enter_only: true,
      screen_text: "OpenCode"
    )
    assert_equal [{ text: "\r", newline: false }], payload.fetch(:steps)
  end

  def test_inject_exit_sends_double_ctrl_c
    writer = StringIO.new
    sleep_calls = []
    @adapter.define_singleton_method(:sleep) { |seconds| sleep_calls << seconds }

    @adapter.inject_exit(writer)

    assert_equal "\u0003\u0003", writer.string
    assert_equal 1, sleep_calls.length
    assert_in_delta 0.1, sleep_calls.first, 0.0001
  end
end
