module Harnex
  module Adapters
    class Codex < Base
      SUBMIT_DELAY_MS = 75
      SEND_WAIT_SECONDS = 2.0

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

      def send_wait_seconds(submit:, enter_only:)
        return 0.0 unless submit
        return 0.0 if enter_only

        SEND_WAIT_SECONDS
      end

      def wait_for_sendable_state?(state, submit:, enter_only:)
        return false unless submit
        return false if enter_only

        state[:input_ready] != true
      end

      def build_send_payload(text:, submit:, enter_only:, screen_text:, force: false)
        state = input_state(screen_text)
        if !force && submit && !enter_only && state[:input_ready] != true
          raise ArgumentError, blocked_message(state, enter_only: enter_only)
        end

        steps = []
        unless enter_only
          body = text.to_s
          steps << { text: body, newline: false } unless body.empty?
        end

        if submit || enter_only
          step = { text: submit_bytes, newline: false }
          step[:delay_ms] = SUBMIT_DELAY_MS if steps.any?
          steps << step
        end

        {
          steps: steps,
          input_state: state,
          force: force
        }
      end

      def inject_exit(writer)
        super(writer, delay_ms: SUBMIT_DELAY_MS)
      end

      protected

      def blocked_message(state, enter_only:)
        return super if enter_only

        "Codex is not at a prompt; wait and retry or use `harnex send --force` (state: #{state[:state]})"
      end
    end
  end
end
