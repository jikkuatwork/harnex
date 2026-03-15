require_relative "../../test_helper"

class GenericAdapterTest < Minitest::Test
  def test_generic_adapter_uses_cli_name_as_command
    adapter = Harnex::Adapters::Generic.new("opencode", ["--model", "x"])
    assert_equal ["opencode"], adapter.base_command
    assert_equal ["opencode", "--model", "x"], adapter.build_command
  end

  def test_build_returns_generic_for_unknown_cli
    adapter = Harnex::Adapters.build("opencode", ["--model", "x"])
    assert_instance_of Harnex::Adapters::Generic, adapter
    assert_equal ["opencode", "--model", "x"], adapter.build_command
  end
end
