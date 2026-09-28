require "time"

module Harnex
  # Observed protocol activity, not output/log freshness. Retains timestamps
  # only: thinking, messages, tool arguments and results never enter this object.
  class ActivityTracker
    MODEL_ITEMS = %w[agentMessage reasoning].freeze
    TOOL_ITEMS = %w[commandExecution mcpToolCall dynamicToolCall fileChange webSearch].freeze
    MODEL_DELTAS = %w[
      item/agentMessage/delta item/reasoning/textDelta item/reasoning/summaryTextDelta
    ].freeze
    TOOL_DELTAS = %w[item/commandExecution/outputDelta item/mcpToolCall/progress].freeze

    def initialize(transport:, monotonic_clock: nil, wall_clock: nil)
      @source = { stdio_jsonl_rpc: "pi_rpc", stdio_jsonrpc: "codex_app_server" }[transport]
      @clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @wall_clock = wall_clock || -> { Time.now }
      @mutex = Mutex.new
      @turn_active = false
      @model_active = false
    end

    def start_turn
      @mutex.synchronize { start_turn_locked } if @source
    end

    def settle
      @mutex.synchronize { @turn_active = @model_active = false } if @source
    end

    def observe_pi(message)
      return unless @source == "pi_rpc"

      @mutex.synchronize do
        case message["type"]
        when "agent_start", "turn_start"
          start_turn_locked
        when "agent_settled"
          @turn_active = @model_active = false
        when "message_start", "message_end"
          if message["message"].is_a?(Hash) && message["message"]["role"] == "assistant"
            model_activity_locked(finished: message["type"] == "message_end")
          end
        when "message_update"
          event = message["assistantMessageEvent"] || {}
          if %w[text_delta thinking_delta toolcall_delta].include?(event["type"]) && !event["delta"].to_s.empty?
            model_activity_locked
          end
        when "tool_execution_start", "tool_execution_update", "tool_execution_end"
          @last_tool = stamp
        end
      end
    end

    def observe_rpc(message)
      return unless @source == "codex_app_server"

      method = message["method"]
      params = message["params"] || {}
      @mutex.synchronize do
        case method
        when "turn/started"
          start_turn_locked
        when "turn/completed"
          @turn_active = @model_active = false
        when "item/started", "item/completed"
          type = params.dig("item", "type")
          if MODEL_ITEMS.include?(type)
            model_activity_locked(finished: method == "item/completed")
          elsif TOOL_ITEMS.include?(type)
            @last_tool = stamp
          end
        when *MODEL_DELTAS
          model_activity_locked unless params["delta"].to_s.empty?
        when *TOOL_DELTAS
          @last_tool = stamp
        end
      end
    end

    def snapshot
      @mutex.synchronize do
        now = @clock.call
        {
          status: @source ? "observed" : "unknown",
          source: @source,
          turn_active: @source ? @turn_active : nil,
          turn_started_at: @turn_active ? @turn_start&.last : nil,
          turn_age_s: @turn_active ? age(@turn_start, now) : nil,
          model_active: @source ? @model_active : nil,
          model_started_at: @model_active ? @model_start&.last : nil,
          model_age_s: @model_active ? age(@model_start, now) : nil,
          last_model_activity_at: @last_model&.last,
          model_idle_s: age(@last_model, now),
          last_tool_activity_at: @last_tool&.last,
          tool_idle_s: age(@last_tool, now)
        }
      end
    end

    private

    def start_turn_locked
      return if @turn_active

      @turn_active = true
      @turn_start = stamp
      @model_active = false
      @model_start = @last_model = @last_tool = nil
    end

    def model_activity_locked(finished: false)
      current = stamp
      @model_start = current unless @model_active || finished
      @last_model = current
      @model_active = !finished
    end

    def stamp
      [@clock.call, @wall_clock.call.getutc.iso8601(3)]
    end

    def age(value, now)
      value ? [now - value.first, 0.0].max.round(3) : nil
    end
  end
end
