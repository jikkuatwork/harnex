module Harnex
  module Adapters
    class Codex < Base
      def initialize(extra_args = [])
        super("codex", extra_args)
      end

      def base_command
        [
          "codex",
          "--dangerously-bypass-approvals-and-sandbox",
          "--no-alt-screen"
        ]
      end

      def infer_repo_path(argv)
        index = 0
        while index < argv.length
          arg = argv[index]
          case arg
          when "-C", "--cd"
            next_value = argv[index + 1]
            return next_value if next_value
            break
          when /\A-C(.+)\z/
            return Regexp.last_match(1)
          end
          index += 1
        end

        Dir.pwd
      end

      def input_state(screen_text)
        lines = recent_lines(screen_text)
        return super unless lines.any? { |line| line.include?("OpenAI Codex") || line.include?("gpt-") }

        if lines.any? { |line| prompt_line?(line) }
          {
            state: "prompt",
            input_ready: true
          }
        else
          {
            state: "session",
            input_ready: nil
          }
        end
      end
    end
  end
end
