require_relative "../test_helper"

class CliTest < Minitest::Test
  def test_bare_harnex_returns_help
    cli = Harnex::CLI.new([])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/Usage:/, out)
    assert_match(/harnex run <cli>/, out)
    assert_match(/harnex logs --id ID/, out)
    assert_match(/harnex pane --id ID/, out)
    assert_match(/logs\s+Read session output transcripts/, out)
    assert_match(/pane\s+Capture the current tmux pane/, out)
  end

  def test_help_logs_returns_logs_usage
    cli = Harnex::CLI.new(["help", "logs"])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/Usage: harnex logs/, out)
  end

  def test_help_pane_returns_pane_usage
    cli = Harnex::CLI.new(["help", "pane"])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/Usage: harnex pane/, out)
  end

  def test_logs_command_dispatches_to_logs_help
    cli = Harnex::CLI.new(["logs", "--help"])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/--follow/, out)
  end

  def test_pane_command_dispatches_to_pane_help
    cli = Harnex::CLI.new(["pane", "--help"])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/--lines N/, out)
  end
end
