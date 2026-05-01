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

  # Regression: after a stream disconnect, error messages push the banner
  # out of the 40-line detection window. The adapter should remember it
  # saw the banner earlier and still detect prompt state.
  def test_detects_prompt_after_banner_scrolls_out
    # First frame: banner visible — latches @banner_seen
    boot_screen = "OpenAI Codex (gpt-4.1)\n› type here\n"
    @adapter.input_state(boot_screen)

    # Second frame: banner gone (stream disconnect filled the screen),
    # but Codex is back at a prompt
    disconnect_screen = (["stream disconnected error line"] * 45).join("\n") + "\n› \n"
    state = @adapter.input_state(disconnect_screen)
    assert_equal "prompt", state[:state]
    assert_equal true, state[:input_ready]
  end

  def test_session_state_after_banner_scrolls_out
    # First frame: banner visible
    boot_screen = "OpenAI Codex (gpt-4.1)\n› type here\n"
    @adapter.input_state(boot_screen)

    # Second frame: banner gone, agent is busy (no prompt marker)
    busy_screen = (["Working on something..."] * 45).join("\n") + "\n"
    state = @adapter.input_state(busy_screen)
    assert_equal "session", state[:state]
    assert_nil state[:input_ready]
  end

  # Regression: OSC sequences in Codex TUI output caused greedy regex to
  # consume the entire buffer, making "OpenAI Codex" undetectable.
  def test_detects_prompt_through_osc_sequences
    screen = "\e]10;?\e\\\e]11;?\e\\\e[3;1H\e[2m│ >_ \e[1mOpenAI Codex\e[22m (v0.114.0) │\n\e[1m› \e[22mtype here\n"
    state = @adapter.input_state(screen)
    assert_equal "prompt", state[:state]
    assert_equal true, state[:input_ready]
  end

  # Regression: Codex v0.121+ draws entirely with cursor positioning.
  # The › prompt is placed via \e[N;1H rather than after a \n, so it
  # was invisible to prompt_line? which checks line-start only.
  def test_detects_prompt_from_cursor_positioned_output
    # Simulate real Codex ring buffer: cursor-addressed TUI, no explicit newlines
    screen = "\e[3;1H\e[2m│ >_ \e[1mOpenAI Codex\e[22m (v0.121.0) │\e[5;1H\e[2mmodel:     gpt-5.4\e[7;1H\e[0mSome answer text\e[32;1H\e[1m\xE2\x80\xBA\e[32;3H\e[22m\e[2mUse /skills\e[0m"
    state = @adapter.input_state(screen)
    assert_equal "prompt", state[:state]
    assert_equal true, state[:input_ready]
  end

  # --- parse_session_summary ---

  def test_parse_session_summary_extracts_token_usage_and_resume_id
    tail = <<~TEXT
      Token usage: total=106,867 input=104,158 (+ 250,880 cached) output=2,709 (reasoning 870)
      To continue this session, run codex resume 019ddf05-0f03-7d70-904f-23db7f00640f
    TEXT

    assert_equal(
      {
        input_tokens: 104_158,
        output_tokens: 2_709,
        reasoning_tokens: 870,
        cached_tokens: 250_880,
        total_tokens: 106_867,
        agent_session_id: "019ddf05-0f03-7d70-904f-23db7f00640f"
      },
      @adapter.parse_session_summary(tail)
    )
  end

  def test_parse_session_summary_returns_nil_fields_for_garbage
    assert_equal(
      {
        input_tokens: nil,
        output_tokens: nil,
        reasoning_tokens: nil,
        cached_tokens: nil,
        total_tokens: nil,
        agent_session_id: nil
      },
      @adapter.parse_session_summary("no usage marker here")
    )
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

  def test_inject_exit_uses_submit_delay
    writer = StringIO.new
    sleep_calls = []
    @adapter.define_singleton_method(:sleep) { |seconds| sleep_calls << seconds }

    @adapter.inject_exit(writer)

    assert_equal "/exit\r", writer.string
    assert_equal 1, sleep_calls.length
    assert_in_delta 0.075, sleep_calls.first, 0.0001
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
