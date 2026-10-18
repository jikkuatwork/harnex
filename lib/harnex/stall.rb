module Harnex
  # #76: one "no progress" predicate over a live status payload, shared by
  # `wait/watch --stall-after` and later observers (#77). It only reads clocks;
  # it never nudges, stops, or judges the worker.
  module Stall
    STRUCTURED_CLOCKS = %w[turn_age_s model_idle_s tool_idle_s].freeze

    module_function

    # Seconds since the session last showed progress, with the clock used:
    #   activity    - structured adapters (Pi, Codex app-server): the most
    #                 recent of turn start, model event, or tool event, and
    #                 only while a turn is active;
    #   output_log  - PTY adapters: seconds since the transcript last changed.
    # nil when no clock applies: settled work, no active structured turn, or
    # nothing observable.
    def progress_idle(payload)
      return nil unless payload.is_a?(Hash)
      return nil if payload["done"] == true || payload["task_complete"] == true || payload["task_failed"] == true

      activity = payload["activity"]
      if activity.is_a?(Hash) && activity["status"] == "observed"
        return nil unless activity["turn_active"] == true

        idle = STRUCTURED_CLOCKS.filter_map { |key| non_negative(activity[key]) }.min
        return idle && { "clock" => "activity", "idle_s" => idle }
      end

      idle = non_negative(payload["log_idle_s"])
      idle && { "clock" => "output_log", "idle_s" => idle }
    end

    def stalled(payload, threshold_s)
      progress = progress_idle(payload)
      return nil unless progress && progress["idle_s"] >= threshold_s

      progress.merge("threshold_s" => threshold_s.to_f)
    end

    def non_negative(value)
      return nil unless value.is_a?(Numeric) && value.finite?

      [value.to_f, 0.0].max
    end
  end
end
