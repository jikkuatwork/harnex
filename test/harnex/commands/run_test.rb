require_relative "../../test_helper"

class RunnerTest < Minitest::Test
  def resolve_watch_options(argv)
    runner = Harnex::Runner.new(argv)
    runner.send(:extract_wrapper_options, argv)
    runner.send(:resolve_watch_preset!)
    runner.instance_variable_get(:@options)
  end

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

  def test_usage_documents_meta
    assert_includes Harnex::Runner.usage, "--meta JSON"
  end

  def test_usage_documents_summary_out
    assert_includes Harnex::Runner.usage, "--summary-out PATH"
  end

  def test_extract_wrapper_options_parses_meta_json
    runner = Harnex::Runner.new(["codex", "--meta", '{"predicted":{"input_tokens":[1,2]},"issue":"23"}'])
    cli_name, forwarded = runner.send(:extract_wrapper_options, ["codex", "--meta", '{"predicted":{"input_tokens":[1,2]},"issue":"23"}'])
    opts = runner.instance_variable_get(:@options)

    assert_equal "codex", cli_name
    assert_equal [], forwarded
    assert_equal({ "predicted" => { "input_tokens" => [1, 2] }, "issue" => "23" }, opts[:meta])
  end

  def test_extract_wrapper_options_rejects_invalid_meta_json
    runner = Harnex::Runner.new(["codex", "--meta", "{"])

    error = assert_raises(OptionParser::InvalidOption) do
      runner.send(:extract_wrapper_options, ["codex", "--meta", "{"])
    end

    assert_match(/--meta must be valid JSON/, error.message)
  end

  def test_extract_wrapper_options_rejects_meta_json_array
    runner = Harnex::Runner.new(["codex", "--meta", "[]"])

    error = assert_raises(OptionParser::InvalidOption) do
      runner.send(:extract_wrapper_options, ["codex", "--meta", "[]"])
    end

    assert_match(/--meta must be a JSON object/, error.message)
  end

  def test_extract_wrapper_options_parses_summary_out
    runner = Harnex::Runner.new(["codex", "--summary-out", "tmp/dispatch.jsonl"])
    cli_name, forwarded = runner.send(:extract_wrapper_options, ["codex", "--summary-out", "tmp/dispatch.jsonl"])
    opts = runner.instance_variable_get(:@options)

    assert_equal "codex", cli_name
    assert_equal [], forwarded
    assert_equal "tmp/dispatch.jsonl", opts[:summary_out]
  end

  def test_resolve_summary_out_defaults_when_koder_dir_exists
    Dir.mktmpdir("harnex-summary-repo") do |repo|
      FileUtils.mkdir_p(File.join(repo, "koder"))
      runner = Harnex::Runner.new(["codex"])

      assert_equal File.join(repo, "koder", "DISPATCH.jsonl"), runner.send(:resolve_summary_out, repo)
    end
  end

  def test_resolve_summary_out_returns_nil_without_koder_dir
    Dir.mktmpdir("harnex-summary-repo") do |repo|
      runner = Harnex::Runner.new(["codex"])

      assert_nil runner.send(:resolve_summary_out, repo)
    end
  end

  def test_resolve_summary_out_expands_explicit_path
    Dir.mktmpdir("harnex-summary-repo") do |repo|
      runner = Harnex::Runner.new(["codex", "--summary-out", "tmp/dispatch.jsonl"])
      runner.send(:extract_wrapper_options, ["codex", "--summary-out", "tmp/dispatch.jsonl"])

      assert_equal File.join(repo, "tmp", "dispatch.jsonl"), runner.send(:resolve_summary_out, repo)
    end
  end

  def test_extract_wrapper_options_bare_watch_enables_babysitter
    runner = Harnex::Runner.new(["codex", "--watch"])
    cli_name, forwarded = runner.send(:extract_wrapper_options, ["codex", "--watch"])
    opts = runner.instance_variable_get(:@options)

    assert_equal "codex", cli_name
    assert_equal [], forwarded
    assert opts[:watch_enabled]
    assert_nil opts[:watch]
  end

  def test_extract_wrapper_options_legacy_watch_path_with_space_is_preserved
    runner = Harnex::Runner.new(["codex", "--watch", "NOTES.md"])
    cli_name, forwarded = runner.send(:extract_wrapper_options, ["codex", "--watch", "NOTES.md"])
    opts = runner.instance_variable_get(:@options)

    assert_equal "codex", cli_name
    assert_equal [], forwarded
    refute opts[:watch_enabled]
    assert_equal "NOTES.md", opts[:watch]
  end

  def test_extract_wrapper_options_legacy_watch_equals_path_is_preserved
    runner = Harnex::Runner.new(["codex", "--watch=NOTES.md"])
    cli_name, forwarded = runner.send(:extract_wrapper_options, ["codex", "--watch=NOTES.md"])
    opts = runner.instance_variable_get(:@options)

    assert_equal "codex", cli_name
    assert_equal [], forwarded
    refute opts[:watch_enabled]
    assert_equal "NOTES.md", opts[:watch]
  end

  def test_extract_wrapper_options_watch_file_sets_file_hook_path
    runner = Harnex::Runner.new(["codex", "--watch-file", "NOTES.md"])
    cli_name, forwarded = runner.send(:extract_wrapper_options, ["codex", "--watch-file", "NOTES.md"])
    opts = runner.instance_variable_get(:@options)

    assert_equal "codex", cli_name
    assert_equal [], forwarded
    assert_equal "NOTES.md", opts[:watch]
  end

  def test_extract_wrapper_options_allows_babysitter_and_file_hook_together
    runner = Harnex::Runner.new(["--watch", "--watch-file", "NOTES.md", "codex"])
    cli_name, forwarded = runner.send(:extract_wrapper_options, ["--watch", "--watch-file", "NOTES.md", "codex"])
    opts = runner.instance_variable_get(:@options)

    assert_equal "codex", cli_name
    assert_equal [], forwarded
    assert opts[:watch_enabled]
    assert_equal "NOTES.md", opts[:watch]
  end

  def test_extract_wrapper_options_parses_stall_after_and_max_resumes
    runner = Harnex::Runner.new(["codex", "--watch", "--stall-after", "5m", "--max-resumes", "2"])
    runner.send(:extract_wrapper_options, ["codex", "--watch", "--stall-after", "5m", "--max-resumes", "2"])
    opts = runner.instance_variable_get(:@options)

    assert_equal 300.0, opts[:stall_after_s]
    assert_equal 2, opts[:max_resumes]
  end

  def test_extract_wrapper_options_rejects_negative_max_resumes
    runner = Harnex::Runner.new(["codex", "--max-resumes", "-1"])

    assert_raises(OptionParser::InvalidArgument) do
      runner.send(:extract_wrapper_options, ["codex", "--max-resumes", "-1"])
    end
  end

  def test_resolve_watch_preset_applies_defaults_for_impl_plan_and_gate
    expectations = {
      "impl" => [8 * 60.0, 1],
      "plan" => [3 * 60.0, 2],
      "gate" => [15 * 60.0, 0]
    }

    expectations.each do |preset, (stall_after_s, max_resumes)|
      options = resolve_watch_options(["codex", "--watch", "--preset", preset])
      assert_equal stall_after_s, options[:stall_after_s]
      assert_equal max_resumes, options[:max_resumes]
    end
  end

  def test_resolve_watch_preset_keeps_explicit_stall_after
    options = resolve_watch_options(["codex", "--watch", "--preset", "impl", "--stall-after", "20m"])
    assert_equal 20 * 60.0, options[:stall_after_s]
    assert_equal 1, options[:max_resumes]
  end

  def test_resolve_watch_preset_rejects_unknown_name
    runner = Harnex::Runner.new(["codex", "--watch", "--preset", "foo"])
    runner.send(:extract_wrapper_options, ["codex", "--watch", "--preset", "foo"])

    error = assert_raises(RuntimeError) { runner.send(:resolve_watch_preset!) }
    assert_equal 'harnex run: unknown --preset "foo" (valid: impl, plan, gate)', error.message
  end

  def test_resolve_watch_preset_requires_watch_mode
    runner = Harnex::Runner.new(["codex", "--preset", "impl"])
    runner.send(:extract_wrapper_options, ["codex", "--preset", "impl"])

    error = assert_raises(RuntimeError) { runner.send(:resolve_watch_preset!) }
    assert_equal "harnex run: --preset requires --watch", error.message
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

  # --tmux flag parsing (issue #20)

  def test_tmux_does_not_consume_following_flag_as_window_name
    runner = Harnex::Runner.new(["codex", "--tmux", "--id", "cx-123"])
    runner.send(:extract_wrapper_options, ["codex", "--tmux", "--id", "cx-123"])
    opts = runner.instance_variable_get(:@options)

    assert opts[:tmux], "tmux should be enabled"
    assert_nil opts[:tmux_name], "--id should not be consumed as tmux window name"
    assert_equal "cx-123", opts[:id]
  end

  def test_tmux_does_not_consume_detach_flag
    runner = Harnex::Runner.new(["codex", "--tmux", "--detach"])
    runner.send(:extract_wrapper_options, ["codex", "--tmux", "--detach"])
    opts = runner.instance_variable_get(:@options)

    assert opts[:tmux]
    assert opts[:detach], "--detach should be parsed as its own flag"
    assert_nil opts[:tmux_name]
  end

  def test_tmux_does_not_consume_unknown_double_dash_flag
    runner = Harnex::Runner.new(["codex", "--tmux", "--name", "cx-p-322"])
    cli_name, forwarded = runner.send(:extract_wrapper_options, ["codex", "--tmux", "--name", "cx-p-322"])

    opts = runner.instance_variable_get(:@options)
    assert opts[:tmux]
    assert_nil opts[:tmux_name], "--name should not be consumed as tmux window name"
    assert_includes forwarded, "--name"
    assert_includes forwarded, "cx-p-322"
  end

  def test_tmux_still_accepts_positional_window_name
    runner = Harnex::Runner.new(["codex", "--tmux", "mywindow"])
    runner.send(:extract_wrapper_options, ["codex", "--tmux", "mywindow"])
    opts = runner.instance_variable_get(:@options)

    assert opts[:tmux]
    assert_equal "mywindow", opts[:tmux_name]
  end

  def test_tmux_equals_syntax_unaffected
    runner = Harnex::Runner.new(["codex", "--tmux=mywindow"])
    runner.send(:extract_wrapper_options, ["codex", "--tmux=mywindow"])
    opts = runner.instance_variable_get(:@options)

    assert opts[:tmux]
    assert_equal "mywindow", opts[:tmux_name]
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
