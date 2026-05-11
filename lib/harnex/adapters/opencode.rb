module Harnex
  module Adapters
    class Opencode < Base
      SUBMIT_DELAY_MS = 75
      SUBMIT_DELAY_PER_KB_MS = 50
      EXIT_SIGNAL_DELAY_MS = 100

      def initialize(extra_args = [])
        super("opencode", extra_args)
        @screen_seen = false
      end

      def provider
        "opencode"
      end

      def base_command
        ["opencode"]
      end

      def infer_repo_path(argv)
        index = 0
        while index < argv.length
          arg = argv[index].to_s
          case arg
          when "--dir"
            next_value = argv[index + 1]
            return next_value if next_value && !next_value.to_s.strip.empty?
            break
          when /\A--dir=(.+)\z/
            return Regexp.last_match(1)
          end
          index += 1
        end

        positional = argv.find { |value| value && !value.start_with?("-") }
        return positional if positional

        Dir.pwd
      end

      def input_state(screen_text)
        @screen_seen ||= !screen_text.to_s.empty?
        lines = recent_lines(screen_text, limit: 80)
        return prompt_state if @screen_seen && lines.empty?
        return prompt_state if lines.any? { |line| prompt_line?(line) }

        compact = lines.join(" ").gsub(/\s+/, " ")

        # OpenCode's TUI keeps rendering on an alternate screen and does
        # not expose a stable prompt token in plain text snapshots. Treat
        # observed screen content as send-ready so inbox messages don't
        # stall indefinitely in :unknown.
        return prompt_state if compact.match?(/\bOpenCode\b/i)
        return prompt_state if compact.match?(/\bSession\b.*\bContinue\b.*\bopencode\s+-s\b/i)
        return prompt_state if compact.match?(/[■⬝╹]/)

        return prompt_state if @screen_seen

        super
      end

      def parse_session_summary(transcript_tail)
        summary = {
          input_tokens: nil,
          output_tokens: nil,
          reasoning_tokens: nil,
          cached_tokens: nil,
          total_tokens: nil,
          agent_session_id: nil
        }

        text = normalized_screen_text(transcript_tail)
        if (match = text.match(/\bContinue\s+opencode\s+-s\s+([A-Za-z0-9._:-]+)/))
          summary[:agent_session_id] = match[1]
        end

        summary
      end

      def build_send_payload(text:, submit:, enter_only:, screen_text:, force: false)
        state = input_state(screen_text)
        if !force && blocked_state?(state, enter_only: enter_only)
          raise ArgumentError, blocked_message(state, enter_only: enter_only)
        end

        steps = []
        unless enter_only
          body = text.to_s
          steps << { text: body, newline: false } unless body.empty?
        end

        if submit || enter_only
          step = { text: submit_bytes, newline: false }
          step[:delay_ms] = submit_delay_ms(text) if steps.any?
          steps << step
        end

        {
          steps: steps,
          input_state: state,
          force: force
        }
      end

      def inject_exit(writer)
        # Ctrl+C is OpenCode's native terminal stop path. A second signal
        # shortly after the first handles "interrupt-first, quit-second"
        # cases when work is in-flight.
        writer.write("\u0003")
        writer.flush
        sleep(EXIT_SIGNAL_DELAY_MS / 1000.0)
        writer.write("\u0003")
        writer.flush
      end

      private

      def prompt_state
        {
          state: "prompt",
          input_ready: true
        }
      end

      def submit_delay_ms(text)
        extra = (text.to_s.bytesize / 1024.0 * SUBMIT_DELAY_PER_KB_MS).ceil
        SUBMIT_DELAY_MS + extra
      end
    end
  end
end
