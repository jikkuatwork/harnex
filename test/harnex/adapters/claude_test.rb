require_relative "../../test_helper"

class ClaudeAdapterTest < Minitest::Test
  def setup
    @adapter = Harnex::Adapters::Claude.new
  end

  # --- input_state ---

  def test_detects_workspace_trust_prompt
    screen = <<~SCREEN
      Quick safety check:
      Do you trust the files in this folder?
      Yes, I trust this folder
    SCREEN
    state = @adapter.input_state(screen)
    assert_equal "workspace-trust-prompt", state[:state]
    assert_equal false, state[:input_ready]
    assert_equal "press-enter-to-confirm", state[:action]
  end

  def test_detects_confirmation_prompt
    screen = <<~SCREEN
      Some content here
      Enter to confirm    Esc to cancel
    SCREEN
    state = @adapter.input_state(screen)
    assert_equal "confirmation", state[:state]
    assert_equal false, state[:input_ready]
  end

  def test_detects_insert_mode_as_prompt
    screen = "some output\n--INSERT--\n"
    state = @adapter.input_state(screen)
    assert_equal "prompt", state[:state]
    assert_equal true, state[:input_ready]
  end

  def test_detects_bypass_permissions_as_prompt
    screen = "some output\nbypass permissions on\n"
    state = @adapter.input_state(screen)
    assert_equal "prompt", state[:state]
    assert_equal true, state[:input_ready]
  end

  def test_detects_normal_mode_as_vim_normal
    screen = "some output\nNORMAL\n"
    state = @adapter.input_state(screen)
    assert_equal "vim-normal", state[:state]
    assert_equal true, state[:input_ready]
  end

  def test_detects_dash_normal_mode_as_vim_normal
    screen = "some output\n--NORMAL--\n"
    state = @adapter.input_state(screen)
    assert_equal "vim-normal", state[:state]
    assert_equal true, state[:input_ready]
  end

  def test_detects_prompt_line_as_prompt
    screen = "some output\n> \n"
    state = @adapter.input_state(screen)
    assert_equal "prompt", state[:state]
    assert_equal true, state[:input_ready]
  end

  def test_unknown_for_generic_output
    screen = "Processing files...\nDoing work...\n"
    state = @adapter.input_state(screen)
    assert_equal "unknown", state[:state]
    assert_nil state[:input_ready]
  end

  # --- build_send_payload blocking ---

  def test_raises_on_workspace_trust_without_enter
    screen = "Quick safety check:\nYes, I trust this folder\n"
    assert_raises(ArgumentError) do
      @adapter.build_send_payload(
        text: "hello",
        submit: true,
        enter_only: false,
        screen_text: screen
      )
    end
  end

  def test_allows_enter_on_workspace_trust
    screen = "Quick safety check:\nYes, I trust this folder\n"
    payload = @adapter.build_send_payload(
      text: "",
      submit: true,
      enter_only: true,
      screen_text: screen
    )
    # Should not raise — enter_only is allowed for workspace trust
    assert_equal false, payload[:input_state][:input_ready]
    assert_equal [{ text: "\r", newline: false }], payload[:steps]
  end

  def test_build_send_payload_sends_submit_as_delayed_second_step
    screen = "some output\n--INSERT--\n"
    payload = @adapter.build_send_payload(
      text: "review this diff",
      submit: true,
      enter_only: false,
      screen_text: screen
    )

    assert_equal 2, payload[:steps].length
    assert_equal "review this diff", payload[:steps][0][:text]
    assert_equal "\r", payload[:steps][1][:text]
    assert_equal 75, payload[:steps][1][:delay_ms]
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

  # --- base_command ---

  def test_base_command
    cmd = @adapter.base_command
    assert_includes cmd, "claude"
    assert_includes cmd, "--dangerously-skip-permissions"
  end
end
