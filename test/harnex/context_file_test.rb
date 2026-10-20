require_relative "../test_helper"
require "tmpdir"

class ContextFileTest < Minitest::Test
  HOLM_BRIEF = <<~MD
    # Brief: row X, Review 999 must-fix (pi-fix998-1020), 2026-10-19

    Sent verbatim as the harnex --context.

    Fix two verified must-fix findings.

    Stop rule: print DONE <sha> and stop.
  MD

  def with_brief(content)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "brief.md")
      File.write(path, content)
      yield path
    end
  end

  def test_whole_file_is_trimmed_and_hashed
    with_brief("\n\n  do the work\n\n") do |path|
      brief = Harnex::ContextFile.load(path)

      assert_equal "  do the work", brief[:text]
      assert_equal File.expand_path(path), brief[:path]
      assert_equal Digest::SHA256.hexdigest("  do the work"), brief[:sha256]
      assert_nil brief[:section]
    end
  end

  def test_plain_marker_line_runs_to_end_of_file
    with_brief(HOLM_BRIEF) do |path|
      brief = Harnex::ContextFile.load(path, section: "Sent verbatim")

      assert_equal "Fix two verified must-fix findings.\n\nStop rule: print DONE <sha> and stop.", brief[:text]
      assert_equal "Sent verbatim", brief[:section]
    end
  end

  def test_heading_section_stops_at_same_or_higher_level
    content = <<~MD
      # Brief
      ## Background
      not sent
      ## Task
      line one
      ### Detail
      kept sub-heading body
      ```sh
      ## not a heading inside a fence
      ```
      ## Next
      not sent either
    MD
    with_brief(content) do |path|
      text = Harnex::ContextFile.load(path, section: "Task")[:text]

      assert_includes text, "line one"
      assert_includes text, "### Detail"
      assert_includes text, "## not a heading inside a fence"
      refute_includes text, "not sent"
    end
  end

  def test_missing_section_is_refused
    with_brief(HOLM_BRIEF) do |path|
      error = assert_raises(Harnex::ContextFile::Error) { Harnex::ContextFile.load(path, section: "Nope") }
      assert_match(/"Nope" not found/, error.message)
    end
  end

  def test_empty_section_is_refused
    with_brief("# Brief\n## Task\n\n   \n## Next\nbody\n") do |path|
      error = assert_raises(Harnex::ContextFile::Error) { Harnex::ContextFile.load(path, section: "Task") }
      assert_match(/empty/, error.message)
    end
  end

  def test_missing_file_is_refused
    error = assert_raises(Harnex::ContextFile::Error) { Harnex::ContextFile.load("/nonexistent/brief.md") }
    assert_match(/not found/, error.message)
  end
end
