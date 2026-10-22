# TextKit: small text helpers.
module TextKit
  module_function

  # "Hello, World!" -> "hello-world"
  def slugify(text)
    text.downcase.strip.gsub(/\s+/, "-")
  end

  # "  some   text " -> "some text"
  def squish(text)
    text.strip.gsub(/\s+/, " ")
  end
end
