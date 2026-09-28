module Harnex
  # Authority over a group created with spawn(pgroup: true), never inferred from
  # an injected PID. Keep this separate from root-child reaping: a tool may
  # outlive its parent and still need KILL after the TERM grace period.
  class OwnedProcessGroup
    def initialize(pgid)
      raise ArgumentError, "owned process group must be positive" unless pgid.is_a?(Integer) && pgid.positive?

      @pgid = pgid
      @mutex = Mutex.new
    end

    def terminate(term_grace_seconds:, kill_grace_seconds:)
      @mutex.synchronize do
        return true unless @pgid
        # Defensive guard even though spawn(pgroup: true) isolates the child.
        return false if @pgid == Process.getpgrp || @pgid == Process.pid

        return true unless signal("TERM")
        return true if wait_until_gone(term_grace_seconds)
        return true unless signal("KILL")

        wait_until_gone(kill_grace_seconds)
      end
    end

    private

    def signal(name)
      Process.kill(name, -@pgid)
      true
    rescue Errno::ESRCH
      # Do not later signal a recycled group ID after observing it gone.
      @pgid = nil
      false
    end

    def wait_until_gone(seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds.to_f
      loop do
        return true unless signal(0)

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return false if remaining <= 0

        sleep([0.01, remaining].min)
      end
    end
  end
end
