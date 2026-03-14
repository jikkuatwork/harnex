require_relative "../../test_helper"

class CodexAdapterTest < Minitest::Test
  def setup
    @adapter = Harnex::Adapters::Codex.new
  end

  # --- input_state ---

  def test_detects_prompt_when_marker_present
    screen = <<~SCREEN
      OpenAI Codex (gpt-4.1)
      some output here
      >
    SCREEN
    state = @adapter.input_state(screen)
    assert_equal "prompt", state[:state]
    assert_equal true, state[:input_ready]
  end

  def test_session_state_when_no_prompt_marker
    screen = <<~SCREEN
      OpenAI Codex (gpt-4.1)
      Working on something...
      Processing files...
    SCREEN
    state = @adapter.input_state(screen)
    assert_equal "session", state[:state]
    assert_nil state[:input_ready]
  end

  def test_unknown_when_no_codex_banner
    screen = "some random terminal output\nno codex here\n"
    state = @adapter.input_state(screen)
    assert_equal "unknown", state[:state]
    assert_nil state[:input_ready]
  end

  # --- build_send_payload ---

  def test_build_send_payload_with_text_and_submit
    screen = "OpenAI Codex (gpt-4.1)\n> \n"
    payload = @adapter.build_send_payload(
      text: "hello",
      submit: true,
      enter_only: false,
      screen_text: screen
    )

    assert payload[:steps]
    texts = payload[:steps].map { |s| s[:text] }
    assert texts.include?("hello")
    assert texts.any? { |t| t == "\r" }
  end

  def test_build_send_payload_enter_only
    screen = "OpenAI Codex (gpt-4.1)\n> \n"
    payload = @adapter.build_send_payload(
      text: "",
      submit: true,
      enter_only: true,
      screen_text: screen
    )

    assert payload[:steps]
    # Should have only the submit step, no text step
    assert_equal 1, payload[:steps].length
    assert_equal "\r", payload[:steps].first[:text]
  end

  def test_build_send_payload_raises_when_not_at_prompt
    screen = "OpenAI Codex (gpt-4.1)\nWorking...\n"
    assert_raises(ArgumentError) do
      @adapter.build_send_payload(
        text: "hello",
        submit: true,
        enter_only: false,
        screen_text: screen
      )
    end
  end

  def test_build_send_payload_force_bypasses_state_check
    screen = "OpenAI Codex (gpt-4.1)\nWorking...\n"
    payload = @adapter.build_send_payload(
      text: "hello",
      submit: true,
      enter_only: false,
      screen_text: screen,
      force: true
    )
    assert payload[:force]
  end

  # --- infer_repo_path ---

  def test_infer_repo_path_from_cd_flag
    assert_equal "/tmp/myrepo", @adapter.infer_repo_path(["-C", "/tmp/myrepo"])
    assert_equal "/tmp/myrepo", @adapter.infer_repo_path(["--cd", "/tmp/myrepo"])
  end

  def test_infer_repo_path_from_compact_flag
    assert_equal "/tmp/myrepo", @adapter.infer_repo_path(["-C/tmp/myrepo"])
  end

  def test_infer_repo_path_defaults_to_pwd
    assert_equal Dir.pwd, @adapter.infer_repo_path([])
  end

  # --- base_command ---

  def test_base_command_includes_bypass_flags
    cmd = @adapter.base_command
    assert_includes cmd, "codex"
    assert_includes cmd, "--dangerously-bypass-approvals-and-sandbox"
    assert_includes cmd, "--no-alt-screen"
  end

  # --- build_command with extra args ---

  def test_build_command_appends_extra_args
    adapter = Harnex::Adapters::Codex.new(["--model", "gpt-4.1"])
    cmd = adapter.build_command
    assert_includes cmd, "--model"
    assert_includes cmd, "gpt-4.1"
  end
end
