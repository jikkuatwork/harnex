require "digest"

module Harnex
  # `harnex run --context-file PATH [--context-section TEXT]` (#83): read a
  # brief from disk, optionally keep only one section, and refuse an empty
  # result so a bad extraction never launches a session with no task.
  module ContextFile
    class Error < StandardError; end

    HEADING = /\A(\#{1,6})[ \t]+(.*?)(?:[ \t]+\#+)?[ \t]*\z/
    FENCE = /\A[ \t]{0,3}(```|~~~)/

    module_function

    # Returns { text:, path:, section:, sha256: }. A section starts at the first
    # line (outside code fences) whose text, with any heading markers removed,
    # begins with SECTION. After a Markdown heading it runs to the next heading
    # of the same or a higher level; after a plain marker line, to end of file.
    def load(path, section: nil)
      absolute = File.expand_path(path)
      raise Error, "--context-file not found: #{path}" unless File.file?(absolute)

      content = File.read(absolute, encoding: "UTF-8")
      raise Error, "--context-file is not valid UTF-8: #{path}" unless content.valid_encoding?

      text = section ? extract_section(content, section, path) : content
      text = trim_blank_lines(text)
      if text.strip.empty?
        where = section ? "section #{section.inspect} of #{path}" : path
        raise Error, "--context-file refused: #{where} is empty"
      end

      { text: text, path: absolute, section: section, sha256: Digest::SHA256.hexdigest(text) }
    end

    def extract_section(content, section, path)
      # "## Task" and "Task" both name the heading "## Task".
      needle = section.to_s.strip.sub(/\A\#{1,6}[ \t]+/, "")
      raise Error, "--context-section needs a non-empty heading" if needle.empty?

      lines = content.lines
      start, level = find_marker(lines, needle)
      raise Error, "--context-section #{section.inspect} not found in #{path}" unless start

      body = lines[(start + 1)..] || []
      return body.join if level.nil?

      in_fence = false
      taken = body.take_while do |line|
        in_fence = !in_fence if line.match?(FENCE)
        next true if in_fence

        heading = line.chomp.match(HEADING)
        heading.nil? || heading[1].length > level
      end
      taken.join
    end

    def find_marker(lines, needle)
      in_fence = false
      lines.each_with_index do |line, index|
        if line.match?(FENCE)
          in_fence = !in_fence
          next
        end
        next if in_fence

        stripped = line.chomp
        heading = stripped.match(HEADING)
        text = heading ? heading[2] : stripped.strip
        next unless text.start_with?(needle)

        return [index, heading && heading[1].length]
      end
      nil
    end

    def trim_blank_lines(text)
      lines = text.lines
      lines.shift while lines.first&.strip&.empty?
      lines.pop while lines.last&.strip&.empty?
      lines.join.chomp
    end
  end
end
