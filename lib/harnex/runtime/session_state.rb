module Harnex
  class SessionState
    STATES = %i[prompt busy blocked unknown].freeze

    attr_reader :state

    def initialize(adapter)
      @adapter = adapter
      @state = :unknown
      @mutex = Mutex.new
      @condvar = ConditionVariable.new
    end

    def update(screen_snapshot)
      input = @adapter.input_state(screen_snapshot)
      new_state =
        case input[:input_ready]
        when true  then :prompt
        when false then :blocked
        else            :unknown
        end

      @mutex.synchronize do
        old = @state
        @state = new_state
        @condvar.broadcast if old != new_state
      end

      new_state
    end

    def force_busy!
      @mutex.synchronize do
        @state = :busy
        @condvar.broadcast
      end
    end

    def force_prompt!
      @mutex.synchronize do
        @state = :prompt
        @condvar.broadcast
      end
    end

    def wait_for_prompt(timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @mutex.synchronize do
        loop do
          return true if @state == :prompt
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return false if remaining <= 0
          @condvar.wait(@mutex, remaining)
        end
      end
    end

    def to_s
      @mutex.synchronize { @state.to_s }
    end
  end
end
