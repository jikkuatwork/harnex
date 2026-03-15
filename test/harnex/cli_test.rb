require_relative "../test_helper"

class CliTest < Minitest::Test
  def test_bare_harnex_returns_help
    cli = Harnex::CLI.new([])
    out, = capture_io { assert_equal 0, cli.run }
    assert_match(/Usage:/, out)
    assert_match(/harnex run <cli>/, out)
  end
end
