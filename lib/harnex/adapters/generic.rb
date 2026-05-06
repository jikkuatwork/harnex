module Harnex
  module Adapters
    class Generic < Base
      def initialize(cli_name, extra_args = [])
        @cli_name = cli_name
        super(cli_name, extra_args)
      end

      def base_command
        [@cli_name]
      end

      def input_state(screen_text)
        if recent_lines(screen_text).any? { |line| prompt_line?(line) }
          {
            state: "prompt",
            input_ready: true
          }
        else
          super
        end
      end
    end
  end
end
