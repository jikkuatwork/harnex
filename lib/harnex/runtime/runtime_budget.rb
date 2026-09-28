require "time"

module Harnex
  # One fixed session deadline. Neither traffic, retries nor prompts can re-arm
  # it. The callback should only schedule stop work, never wait for RPC or I/O.
  class RuntimeBudget
    def initialize(seconds:, monotonic_clock: nil, wall_clock: nil)
      @seconds = Float(seconds)
      raise ArgumentError, "runtime budget must be finite and positive" unless @seconds.finite? && @seconds.positive?

      @clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @wall_clock = wall_clock || -> { Time.now }
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @expired = @cancelled = false
    end

    def start(&on_expire)
      raise ArgumentError, "runtime budget requires a callback" unless on_expire

      @mutex.synchronize do
        return false if @deadline || @cancelled

        @started_at = @wall_clock.call
        @deadline = @clock.call + @seconds
        @on_expire = on_expire
        @thread = Thread.new do
          @mutex.synchronize do
            until @cancelled || @expired
              remaining = @deadline - @clock.call
              break unless remaining.positive?

              @condition.wait(@mutex, remaining)
            end
          end
          check!
        end
      end
      true
    end

    # Also usable at a dispatch boundary so an expired timer can never admit a
    # new prompt merely because its timer thread has not been scheduled yet.
    def check!
      callback = @mutex.synchronize do
        return false if @expired || @cancelled || !deadline_reached?

        @expired = true
        @condition.broadcast
        @on_expire
      end
      callback.call
      true
    end

    def expired?
      @mutex.synchronize { @expired || (!@cancelled && deadline_reached?) }
    end

    def cancel
      thread = @mutex.synchronize do
        @cancelled = true
        @condition.broadcast
        @thread
      end
      thread&.join(0.2) unless thread == Thread.current
    end

    def snapshot
      @mutex.synchronize do
        state = if @expired || (!@cancelled && deadline_reached?)
                  "expired"
                elsif @cancelled
                  "cancelled"
                elsif @deadline
                  "running"
                else
                  "unarmed"
                end
        {
          limit_s: @seconds,
          state: state,
          started_at: @started_at&.getutc&.iso8601(3),
          deadline_at: @started_at ? (@started_at + @seconds).getutc.iso8601(3) : nil,
          remaining_s: @deadline && state == "running" ? [@deadline - @clock.call, 0.0].max.round(3) : nil
        }
      end
    end

    private

    def deadline_reached?
      !!@deadline && @clock.call >= @deadline
    end
  end
end
