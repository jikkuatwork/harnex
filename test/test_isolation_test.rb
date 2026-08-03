require_relative "test_helper"

# The isolation net itself needs coverage: if it silently stopped reaping,
# the suite would drift back to order-dependent failures that only appear at
# some seeds, which is exactly what it exists to prevent.
class TestIsolationTest < Minitest::Test
  class Probe < Minitest::Test
    def test_nothing; end
  end

  def test_a_thread_leaked_by_a_test_is_reaped_at_the_boundary
    probe = Probe.new(:test_nothing)
    probe.before_setup

    running = Queue.new
    leaked = Thread.new do
      running << :up
      sleep
    end
    running.pop
    assert leaked.alive?, "fixture thread should be running"

    probe.after_teardown

    refute leaked.alive?, "a thread left running by a test must be reaped"
  ensure
    leaked&.kill
  end

  def test_threads_that_predate_the_test_are_left_alone
    survivor_gate = Queue.new
    survivor = Thread.new { survivor_gate.pop }

    probe = Probe.new(:test_nothing)
    probe.before_setup
    probe.after_teardown

    assert survivor.alive?, "threads a test did not start must not be reaped"
  ensure
    survivor_gate&.push(:done)
    survivor&.join(2)
  end

  def test_reap_thread_returns_once_the_thread_is_dead
    finished = Thread.new { :done }
    assert_nil reap_thread(nil)
    refute reap_thread(finished).alive?

    blocked = Thread.new { sleep }
    reap_thread(blocked, timeout: 1)
    refute blocked.alive?, "reap_thread must confirm death, not just signal it"
  end

  def test_reap_process_blocks_until_the_child_is_gone
    pid = spawn("sleep", "30")
    reap_process(pid)

    assert_raises(Errno::ESRCH, Errno::ECHILD) { Process.kill(0, pid) }
  end
end
