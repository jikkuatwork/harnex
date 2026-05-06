require_relative "../test_helper"

class CliTest < Minitest::Test
  def test_bare_harnex_returns_help
    cli = Harnex::CLI.new([])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/Usage:/, out)
    assert_match(/harnex run <cli>/, out)
    assert_match(/harnex logs --id ID/, out)
    assert_match(/harnex events --id ID/, out)
    assert_match(/harnex pane --id ID/, out)
    assert_match(/harnex agents-guide \[topic\]/, out)
    assert_match(/logs\s+Read session output transcripts/, out)
    assert_match(/events\s+Stream per-session JSONL runtime events/, out)
    assert_match(/pane\s+Capture the current tmux pane/, out)
    assert_match(/Working with agents .* harnex agents-guide/, out)
  end

  def test_help_logs_returns_logs_usage
    cli = Harnex::CLI.new(["help", "logs"])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/Usage: harnex logs/, out)
  end

  def test_help_events_returns_events_usage
    cli = Harnex::CLI.new(["help", "events"])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/Usage: harnex events/, out)
  end

  def test_help_pane_returns_pane_usage
    cli = Harnex::CLI.new(["help", "pane"])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/Usage: harnex pane/, out)
  end

  def test_help_agents_guide_returns_agents_guide_usage
    cli = Harnex::CLI.new(["help", "agents-guide"])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/Usage: harnex agents-guide/, out)
  end

  def test_logs_command_dispatches_to_logs_help
    cli = Harnex::CLI.new(["logs", "--help"])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/--follow/, out)
  end

  def test_events_command_dispatches_to_events_help
    cli = Harnex::CLI.new(["events", "--help"])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/--snapshot/, out)
  end

  def test_pane_command_dispatches_to_pane_help
    cli = Harnex::CLI.new(["pane", "--help"])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/--lines N/, out)
  end

  def test_agents_guide_command_dispatches
    cli = Harnex::CLI.new(["agents-guide", "naming"])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/Naming Conventions/, out)
  end
end
