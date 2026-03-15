require_relative "../test_helper"

class CliTest < Minitest::Test
  def test_bare_harnex_returns_help
    cli = Harnex::CLI.new([])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/Usage:/, out)
    assert_match(/harnex run <cli>/, out)
    assert_match(/harnex logs --id ID/, out)
    assert_match(/logs\s+Read session output transcripts/, out)
  end

  def test_help_logs_returns_logs_usage
    cli = Harnex::CLI.new(["help", "logs"])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/Usage: harnex logs/, out)
  end

  def test_logs_command_dispatches_to_logs_help
    cli = Harnex::CLI.new(["logs", "--help"])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/--follow/, out)
  end
end
