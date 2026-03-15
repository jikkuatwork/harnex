module Harnex
  module Adapters
    class Claude < Base
      SUBMIT_DELAY_MS = 75

      def initialize(extra_args = [])
        super("claude", extra_args)
      end

      def base_command
        [
          "claude",
          "--dangerously-skip-permissions"
        ]
      end

      def input_state(screen_text)
        lines = recent_lines(screen_text, limit: 20)
        text = lines.join
        compact = text.gsub(/\s+/, "")

        if compact.include?("Quicksafetycheck:") && compact.include?("Yes,Itrustthisfolder")
          {
            state: "workspace-trust-prompt",
            input_ready: false,
            action: "press-enter-to-confirm"
          }
        elsif compact.include?("Entertoconfirm") && compact.include?("Esctocancel")
          {
            state: "confirmation",
            input_ready: false
          }
        elsif compact.include?("--INSERT--") || compact.include?("bypasspermissionson")
          {
            state: "prompt",
            input_ready: true
          }
        elsif compact.include?("NORMAL") || compact.include?("--NORMAL--")
          {
            state: "vim-normal",
            input_ready: true
          }
        elsif lines.any? { |line| prompt_line?(line) }
          {
            state: "prompt",
            input_ready: true
          }
        else
          super
        end
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

      def allow_control_action?(state, enter_only:)
        enter_only && state[:state] == "workspace-trust-prompt"
      end

      def blocked_message(state, enter_only:)
        return super unless state[:state] == "workspace-trust-prompt"

        if enter_only
          "Claude is waiting on the workspace trust prompt"
        else
          "Claude is waiting on the workspace trust prompt; use `harnex send --submit-only` first or `--force` to bypass"
        end
      end
    end
  end
end
