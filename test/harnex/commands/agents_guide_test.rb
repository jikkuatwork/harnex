require_relative "../../test_helper"

class AgentsGuideCommandTest < Minitest::Test
  def test_list_prints_available_guides
    out, = capture_io { assert_equal 0, Harnex::AgentsGuide.new([]).run }

    assert_includes out, "Agent guides:"
    assert_includes out, "01_dispatch"
    assert_includes out, "05_naming"
    assert_includes out, "harnex agents-guide show <topic>"
  end

  def test_show_by_number_prefix
    out, = capture_io { assert_equal 0, Harnex::AgentsGuide.new(["show", "01"]).run }

    assert_includes out, "# Dispatch: Fire and Watch"
    assert_includes out, "Return Channel First"
  end

  def test_show_by_bare_name
    out, = capture_io { assert_equal 0, Harnex::AgentsGuide.new(["monitoring"]).run }

    assert_includes out, "# Monitoring Patterns"
    assert_includes out, "Completion Test"
  end

  def test_missing_topic_returns_error
    _out, err = capture_io { assert_equal 1, Harnex::AgentsGuide.new(["missing-topic"]).run }

    assert_includes err, "no topic matching"
  end
end
