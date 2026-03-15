require "stringio"

require_relative "../../test_helper"

class BaseAdapterContractTest < Minitest::Test
  class RecordingWriter
    attr_reader :events, :string

    def initialize
      @events = []
      @string = +""
    end

    def write(text)
      @events << [:write, text]
      @string << text
      text.bytesize
    end

    def flush
      @events << [:flush]
    end
  end

  class CustomExitAdapter < Harnex::Adapters::Base
    def initialize
      super("custom")
    end

    def base_command
      ["custom"]
    end

    def inject_exit(writer)
      writer.write("quit\r")
      writer.flush
    end
  end

  def test_base_inject_exit_writes_default_sequence_without_sleep_when_delay_zero
    writer = RecordingWriter.new
    adapter = Harnex::Adapters::Base.new("test")
    sleep_calls = []
    adapter.define_singleton_method(:sleep) { |seconds| sleep_calls << seconds }

    adapter.inject_exit(writer, delay_ms: 0)

    assert_equal "/exit\r", writer.string
    assert_equal [[:write, "/exit"], [:flush], [:write, "\r"], [:flush]], writer.events
    assert_empty sleep_calls
  end

  def test_base_inject_exit_sleeps_before_submit_when_delay_is_positive
    writer = RecordingWriter.new
    adapter = Harnex::Adapters::Base.new("test")
    sleep_calls = []
    adapter.define_singleton_method(:sleep) { |seconds| sleep_calls << seconds }

    adapter.inject_exit(writer, delay_ms: 75)

    assert_equal "/exit\r", writer.string
    assert_equal [[:write, "/exit"], [:flush], [:write, "\r"], [:flush]], writer.events
    assert_equal 1, sleep_calls.length
    assert_in_delta 0.075, sleep_calls.first, 0.0001
  end

  def test_wait_for_sendable_returns_immediately_when_force_true
    adapter = Harnex::Adapters::Base.new("test")
    calls = 0

    snapshot = adapter.wait_for_sendable(-> {
      calls += 1
      "screen-#{calls}"
    }, submit: true, enter_only: false, force: true)

    assert_equal "screen-1", snapshot
    assert_equal 1, calls
  end

  def test_custom_adapter_can_override_inject_exit
    writer = StringIO.new
    CustomExitAdapter.new.inject_exit(writer)
    assert_equal "quit\r", writer.string
  end

  # Regression: OSC regex was greedy and consumed text between multiple
  # OSC sequences (e.g. \e]10;?\e\\ ... \e]11;?\e\\), eating the entire
  # screen buffer. Non-greedy *? fix preserves printable content.
  def test_normalized_screen_text_preserves_content_between_osc_sequences
    adapter = Harnex::Adapters::Base.new("test")
    screen = "\e]10;?\e\\\e]11;?\e\\visible text here\e[0m"
    result = adapter.send(:normalized_screen_text, screen)
    assert_includes result, "visible text here"
  end

  def test_normalized_screen_text_handles_codex_tui_output
    adapter = Harnex::Adapters::Base.new("test")
    # Simulates Codex TUI: OSC queries followed by cursor-addressed content
    screen = "\e]10;?\e\\\e]11;?\e\\\e[?2026h\e[3;1H\e[2m│ >_ \e[1mOpenAI Codex\e[22m (v0.114.0) │\e[5;1H\e[2m│\e[22m\n\e[1m› \e[22mtype here"
    result = adapter.send(:normalized_screen_text, screen)
    assert_includes result, "OpenAI Codex"
    assert_includes result, "› type here"
  end
end
