module Harnex
  module Adapters
    class Base
      PROMPT_PREFIXES = [">", "\u203A", "\u276F"].freeze

      attr_reader :key

      def initialize(key, extra_args = [])
        @key = key
        @extra_args = extra_args.dup
      end

      def build_command
        base_command + @extra_args
      end

      def base_command
        raise NotImplementedError, "#{self.class} must define #base_command"
      end

      def infer_repo_path(_argv)
        Dir.pwd
      end

      def input_state(screen_text)
        {
          state: "unknown",
          input_ready: nil
        }
      end

      def send_wait_seconds(submit:, enter_only:)
        0.0
      end

      def wait_for_sendable_state?(_state, submit:, enter_only:)
        false
      end

      def build_send_payload(text:, submit:, enter_only:, screen_text:, force: false)
        state = input_state(screen_text)
        if !force && blocked_state?(state, enter_only: enter_only)
          raise ArgumentError, blocked_message(state, enter_only: enter_only)
        end

        payload = enter_only ? "" : text.to_s
        payload << submit_bytes if submit || enter_only

        {
          text: payload,
          newline: false,
          input_state: state,
          force: force
        }
      end

      def submit_bytes
        "\r"
      end

      protected

      def blocked_state?(state, enter_only:)
        state[:input_ready] == false && !allow_control_action?(state, enter_only: enter_only)
      end

      def allow_control_action?(_state, enter_only:)
        enter_only ? false : false
      end

      def blocked_message(state, enter_only:)
        suffix = enter_only ? " for Enter-only input" : ""
        "session is not ready for #{key} prompt input#{suffix} (state: #{state[:state]})"
      end

      def prompt_line?(line)
        stripped = line.to_s.strip
        return false if stripped.empty?
        return false if stripped.match?(/\A(?:[>\u203A\u276F]\s*)?\d+\./)

        PROMPT_PREFIXES.any? { |prefix| stripped.start_with?(prefix) }
      end

      def recent_lines(screen_text, limit: 40)
        normalized_screen_text(screen_text).lines.last(limit)
      end

      def normalized_screen_text(screen_text)
        text = screen_text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
        text = text.gsub(/\e\][^\a]*(?:\a|\e\\)/, "")
        text = text.gsub(/\e(?:[@-Z\\-_]|\[[0-?]*[ -\/]*[@-~])/, "")
        text.gsub(/\r\n?/, "\n")
      end
    end
  end
end
