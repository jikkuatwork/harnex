require_relative "../../test_helper"

class ExiterTest < Minitest::Test
  # --- help ---

  def test_help_returns_zero
    exiter = Harnex::Exiter.new(["--help"])
    assert_output(/Usage:/) { assert_equal 0, exiter.run }
  end

  # --- requires --id ---

  def test_raises_without_id
    exiter = Harnex::Exiter.new([])
    assert_raises(RuntimeError) { exiter.run }
  end

  # --- no session found ---

  def test_returns_1_when_no_session
    exiter = Harnex::Exiter.new(["--id", "nonexistent"])
    assert_output(nil, /no session found/) { assert_equal 1, exiter.run }
  end
end

class AdapterExitSequenceTest < Minitest::Test
  def test_base_exit_sequence
    adapter = Harnex::Adapters::Base.new("test")
    assert_equal "/exit\n", adapter.exit_sequence
  end

  def test_codex_exit_sequence
    adapter = Harnex::Adapters::Codex.new
    assert_equal "/exit\n", adapter.exit_sequence
  end

  def test_claude_exit_sequence
    adapter = Harnex::Adapters::Claude.new
    assert_equal "/exit\n", adapter.exit_sequence
  end
end
