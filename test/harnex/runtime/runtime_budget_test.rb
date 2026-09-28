require_relative "../../test_helper"

class RuntimeBudgetTest < Minitest::Test
  def teardown
    @budget&.cancel
  end

  def test_budget_arms_once_and_uses_monotonic_time
    mono = 50.0
    wall = Time.utc(2026, 9, 28)
    calls = 0
    @budget = Harnex::RuntimeBudget.new(seconds: 30, monotonic_clock: -> { mono }, wall_clock: -> { wall })
    assert_equal "unarmed", @budget.snapshot[:state]
    assert @budget.start { calls += 1 }
    refute @budget.start { flunk("must not replace callback or reset deadline") }
    mono += 20
    wall -= 3_600
    assert_equal 10.0, @budget.snapshot[:remaining_s]
    assert_equal "2026-09-28T00:00:30.000Z", @budget.snapshot[:deadline_at]
    mono += 10
    assert @budget.expired?
    assert @budget.check!
    refute @budget.check!
    assert_equal 1, calls
    assert_equal "expired", @budget.snapshot[:state]
  end

  def test_cancel_disarms_pending_timer_without_waiting_for_its_deadline
    @budget = Harnex::RuntimeBudget.new(seconds: 3_600)
    @budget.start { flunk("cancelled timer fired") }
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @budget.cancel
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 0.5
    assert_equal "cancelled", @budget.snapshot[:state]
    refute @budget.expired?
    refute @budget.check!
    refute @budget.instance_variable_get(:@thread).alive?
  end

  def test_expiry_fires_without_a_supervisor_or_activity_callbacks
    fired = Queue.new
    @budget = Harnex::RuntimeBudget.new(seconds: 0.03)
    @budget.start { fired << true }
    assert Timeout.timeout(1) { fired.pop }
    assert_equal "expired", @budget.snapshot[:state]
  end

  def test_invalid_limits_are_rejected
    [0, -1, Float::INFINITY, Float::NAN, "garbage"].each do |value|
      assert_raises(ArgumentError) { Harnex::RuntimeBudget.new(seconds: value) }
    end
  end
end
