require_relative "../../test_helper"

class RunnerTest < Minitest::Test
  def with_env(overrides)
    saved = {}
    overrides.each do |key, value|
      saved[key] = ENV[key]
      ENV[key] = value
    end
    yield
  ensure
    overrides.each { |key, _| saved[key] ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def test_extract_wrapper_options_rejects_single_dash_flag_as_value
    runner = Harnex::Runner.new(["codex", "--host", "-v"])

    error = assert_raises(OptionParser::MissingArgument) do
      runner.send(:extract_wrapper_options, ["codex", "--host", "-v"])
    end

    assert_match(/--host/, error.message)
  end

  def test_required_option_value_allows_negative_numbers
    runner = Harnex::Runner.new([])
    assert_equal "-1", runner.send(:required_option_value, "--timeout", "-1")
  end

  def test_extract_wrapper_options_parses_inbox_ttl
    runner = Harnex::Runner.new(["--inbox-ttl", "45", "codex"])
    cli_name, forwarded = runner.send(:extract_wrapper_options, ["--inbox-ttl", "45", "codex"])

    assert_equal "codex", cli_name
    assert_equal [], forwarded
    assert_equal 45.0, runner.instance_variable_get(:@options)[:inbox_ttl]
  end

  def test_runner_uses_env_default_for_inbox_ttl
    with_env("HARNEX_INBOX_TTL" => "12.5") do
      runner = Harnex::Runner.new([])
      assert_equal 12.5, runner.instance_variable_get(:@options)[:inbox_ttl]
    end
  end
end
