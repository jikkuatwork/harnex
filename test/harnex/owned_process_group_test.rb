require_relative "../test_helper"

class OwnedProcessGroupTest < Minitest::Test
  def test_term_and_kill_target_only_the_owned_group_with_bounded_waits
    group = Harnex::OwnedProcessGroup.new(424242)
    calls = []
    Process.stub(:kill, ->(signal, target) { calls << [signal, target]; 1 }) do
      refute group.terminate(term_grace_seconds: 0, kill_grace_seconds: 0)
    end
    assert_equal [["TERM", -424242], [0, -424242], ["KILL", -424242], [0, -424242]], calls
  end

  def test_gone_group_is_forgotten_and_never_signalled_again
    group = Harnex::OwnedProcessGroup.new(424242)
    calls = []
    Process.stub(:kill, ->(signal, target) { calls << [signal, target]; raise Errno::ESRCH }) do
      2.times { assert group.terminate(term_grace_seconds: 0, kill_grace_seconds: 0) }
    end
    assert_equal [["TERM", -424242]], calls
  end

  def test_cannot_signal_runner_or_its_group
    [Process.pid, Process.getpgrp].each do |pgid|
      group = Harnex::OwnedProcessGroup.new(pgid)
      Process.stub(:kill, ->(*_args) { flunk "must not signal the runner's group" }) do
        refute group.terminate(term_grace_seconds: 0, kill_grace_seconds: 0)
      end
    end
  end

  def test_nonpositive_group_ids_are_not_authority
    [nil, 0, -1].each do |pgid|
      assert_raises(ArgumentError) { Harnex::OwnedProcessGroup.new(pgid) }
    end
  end
end
