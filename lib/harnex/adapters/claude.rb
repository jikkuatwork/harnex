module Harnex
  module Adapters
    class Claude < Base
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
        elsif lines.any? { |line| prompt_line?(line) }
          {
            state: "prompt",
            input_ready: true
          }
        else
          super
        end
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
          "Claude is waiting on the workspace trust prompt; use `harnex send --enter` first or `--force` to bypass"
        end
      end
    end
  end
end
