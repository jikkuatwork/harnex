require "stringio"

require_relative "../../test_helper"

class BaseAdapterContractTest < Minitest::Test
  class CustomExitAdapter < Harnex::Adapters::Base
    def initialize
      super("custom")
    end

    def base_command
      ["custom"]
    end

    def inject_exit(writer)
      writer.write("quit\r")
      writer.flush
    end
  end

  def test_base_inject_exit_writes_default_sequence
    writer = StringIO.new
    Harnex::Adapters::Base.new("test").inject_exit(writer)
    assert_equal "/exit\r", writer.string
  end

  def test_wait_for_sendable_returns_immediately_when_force_true
    adapter = Harnex::Adapters::Base.new("test")
    calls = 0

    snapshot = adapter.wait_for_sendable(-> {
      calls += 1
      "screen-#{calls}"
    }, submit: true, enter_only: false, force: true)

    assert_equal "screen-1", snapshot
    assert_equal 1, calls
  end

  def test_custom_adapter_can_override_inject_exit
    writer = StringIO.new
    CustomExitAdapter.new.inject_exit(writer)
    assert_equal "quit\r", writer.string
  end
end
