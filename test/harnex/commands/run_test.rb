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

  def test_validate_unique_id_raises_when_session_exists
    repo_root = Dir.pwd
    id = "dup-test-#{$$}"
    registry_path = Harnex.registry_path(repo_root, id)

    Harnex.write_registry(registry_path, {
      "id" => id,
      "pid" => Process.pid,
      "host" => "127.0.0.1",
      "port" => 44444,
      "token" => "test",
      "repo_root" => repo_root
    })

    runner = Harnex::Runner.new(["codex", "--id", id])
    runner.send(:extract_wrapper_options, ["codex", "--id", id])

    error = assert_raises(RuntimeError) { runner.send(:validate_unique_id!, repo_root) }
    assert_match(/already active/, error.message)
    assert_match(/#{id}/, error.message)
  ensure
    FileUtils.rm_f(registry_path) if registry_path
  end

  def test_validate_unique_id_passes_when_no_session
    repo_root = Dir.pwd
    id = "unique-test-#{$$}"

    runner = Harnex::Runner.new(["codex", "--id", id])
    runner.send(:extract_wrapper_options, ["codex", "--id", id])

    # Should not raise
    runner.send(:validate_unique_id!, repo_root)
  end

  def test_annotate_tmux_registry_persists_tmux_metadata
    repo_root = Dir.pwd
    id = "tmux-meta-#{$$}"
    path = Harnex.registry_path(repo_root, id)
    payload = {
      "id" => id,
      "pid" => Process.pid,
      "host" => "127.0.0.1",
      "port" => 44445,
      "token" => "test",
      "repo_root" => repo_root,
      "registry_path" => path
    }
    Harnex.write_registry(path, payload.reject { |key, _| key == "registry_path" })

    runner = Harnex::Runner.new(["codex", "--id", id])
    runner.send(:extract_wrapper_options, ["codex", "--id", id])

    discovery = { target: "%31", session_name: "harnex", window_name: "cx-31" }
    original_tmux_lookup = Harnex.method(:tmux_pane_for_pid)
    Harnex.define_singleton_method(:tmux_pane_for_pid) { |_pid| discovery }
    updated = runner.send(:annotate_tmux_registry, payload)

    assert_equal "%31", updated["tmux_target"]
    assert_equal "harnex", updated["tmux_session"]
    assert_equal "cx-31", updated["tmux_window"]

    persisted = JSON.parse(File.read(path))
    assert_equal "%31", persisted["tmux_target"]
    assert_equal "harnex", persisted["tmux_session"]
    assert_equal "cx-31", persisted["tmux_window"]
  ensure
    Harnex.define_singleton_method(:tmux_pane_for_pid, &original_tmux_lookup) if original_tmux_lookup
    FileUtils.rm_f(path) if path
  end
end
