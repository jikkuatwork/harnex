require "minitest/autorun"
require "textkit"

class TextKitTest < Minitest::Test
  def test_slugify_joins_words_with_dashes
    assert_equal "hello-big-world", TextKit.slugify("Hello Big World")
  end

  def test_squish_collapses_whitespace
    assert_equal "some text", TextKit.squish("  some   text ")
  end
end
