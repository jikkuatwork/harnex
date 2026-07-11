require_relative "../../test_helper"
require "open3"
require "rbconfig"

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

  def test_extract_wrapper_options_parses_auto_stop
    runner = Harnex::Runner.new(["codex", "--context", "do work", "--auto-stop"])
    cli_name, forwarded = runner.send(:extract_wrapper_options, ["codex", "--context", "do work", "--auto-stop"])
    opts = runner.instance_variable_get(:@options)

    assert_equal "codex", cli_name
    assert_equal [], forwarded
    assert opts[:auto_stop]
  end

  def test_extract_wrapper_options_parses_fast
    runner = Harnex::Runner.new(["codex", "--fast"])
    cli_name, forwarded = runner.send(:extract_wrapper_options, ["codex", "--fast"])
    opts = runner.instance_variable_get(:@options)

    assert_equal "codex", cli_name
    assert_equal [], forwarded
    assert opts[:fast]
  end

  def test_codex_service_tier_defaults_to_flex
    runner = Harnex::Runner.new(["codex"])
    cli_name, child_args = runner.send(:extract_wrapper_options, ["codex"])

    assert_equal ["-c", "service_tier=\"flex\""],
      runner.send(:apply_codex_service_tier, cli_name, child_args)
  end

  def test_codex_fast_sets_fast_service_tier
    runner = Harnex::Runner.new(["codex", "--fast"])
    cli_name, child_args = runner.send(:extract_wrapper_options, ["codex", "--fast"])

    assert_equal ["-c", "service_tier=\"fast\""],
      runner.send(:apply_codex_service_tier, cli_name, child_args)
  end

  def test_codex_service_tier_respects_explicit_child_config
    runner = Harnex::Runner.new(["codex", "--", "-c", "service_tier=\"fast\""])
    cli_name, child_args = runner.send(:extract_wrapper_options, ["codex", "--", "-c", "service_tier=\"fast\""])

    assert_equal ["-c", "service_tier=\"fast\""],
      runner.send(:apply_codex_service_tier, cli_name, child_args)
  end

  def test_codex_service_tier_respects_explicit_equals_child_config
    runner = Harnex::Runner.new(["codex", "--", "--config=service_tier=\"fast\""])
    cli_name, child_args = runner.send(:extract_wrapper_options, ["codex", "--", "--config=service_tier=\"fast\""])

    assert_equal ["--config=service_tier=\"fast\""],
      runner.send(:apply_codex_service_tier, cli_name, child_args)
  end

  def test_cli_defaults_codex_app_server_to_flex_service_tier
    assert_codex_service_tier_argv([], "flex")
  end

  def test_cli_fast_uses_fast_service_tier
    assert_codex_service_tier_argv(["--fast"], "fast")
  end

  def test_non_codex_does_not_get_service_tier
    runner = Harnex::Runner.new(["claude"])
    cli_name, child_args = runner.send(:extract_wrapper_options, ["claude"])

    assert_equal [], runner.send(:apply_codex_service_tier, cli_name, child_args)
  end

  def test_extract_wrapper_options_allows_known_auto_stop_before_separator
    runner = Harnex::Runner.new(["codex", "--auto-stop", "--", "echo", "hi"])
    cli_name, forwarded = runner.send(:extract_wrapper_options, ["codex", "--auto-stop", "--", "echo", "hi"])
    opts = runner.instance_variable_get(:@options)

    assert_equal "codex", cli_name
    assert_equal ["echo", "hi"], forwarded
    assert opts[:auto_stop]
  end

  def test_extract_wrapper_options_rejects_unknown_long_flag_before_separator
    runner = Harnex::Runner.new(["codex", "--until", "task_complete", "--", "echo", "hi"])

    error = assert_raises(OptionParser::InvalidOption) do
      runner.send(:extract_wrapper_options, ["codex", "--until", "task_complete", "--", "echo", "hi"])
    end

    assert_match(/--until/, error.message)
    assert_match(/harnex run --help/, error.message)
  end

  def test_extract_wrapper_options_forwards_agent_flags_after_separator
    runner = Harnex::Runner.new(["codex", "--", "--until", "task_complete", "echo", "hi"])
    cli_name, forwarded = runner.send(:extract_wrapper_options, ["codex", "--", "--until", "task_complete", "echo", "hi"])

    assert_equal "codex", cli_name
    assert_equal ["--until", "task_complete", "echo", "hi"], forwarded
  end

  def test_extract_wrapper_options_rejects_unknown_long_flag_without_separator
    runner = Harnex::Runner.new(["codex", "--foo-bar"])

    error = assert_raises(OptionParser::InvalidOption) do
      runner.send(:extract_wrapper_options, ["codex", "--foo-bar"])
    end

    assert_match(/--foo-bar/, error.message)
    assert_match(/harnex run --help/, error.message)
  end

  def test_cli_rejects_unknown_run_flag_before_spawning_agent
    _stdout, stderr, status = Open3.capture3(
      Gem.ruby,
      "-I#{File.expand_path('../../../lib', __dir__)}",
      File.expand_path("../../../bin/harnex", __dir__),
      "run", "codex", "--until", "task_complete", "--", "echo", "hi"
    )

    refute status.success?
    assert_includes stderr, "--until"
    assert_includes stderr, "harnex run --help"
  end

  def test_auto_stop_requires_context
    runner = Harnex::Runner.new(["codex", "--auto-stop"])
    runner.send(:extract_wrapper_options, ["codex", "--auto-stop"])

    error = assert_raises(OptionParser::InvalidOption) { runner.send(:validate_auto_stop_context!) }

    assert_match(/--auto-stop requires --context/, error.message)
  end

  def test_usage_documents_meta
    assert_includes Harnex::Runner.usage, "--meta JSON"
  end

  def test_usage_documents_auto_stop
    assert_includes Harnex::Runner.usage, "--auto-stop"
  end

  def test_usage_documents_fast
    assert_includes Harnex::Runner.usage, "--fast"
  end

  def test_auto_stop_exits_when_jsonrpc_interrupt_never_answers
    Dir.mktmpdir("harnex-autostop-run") do |repo|
      bin_dir = File.join(repo, "bin")
      FileUtils.mkdir_p(bin_dir)
      write_hanging_interrupt_codex_stub(File.join(bin_dir, "codex"))

      id = "autostop-hang-#{$$}"
      summary_path = File.join(repo, "DISPATCH.jsonl")
      stdout_path = File.join(repo, "stdout.log")
      stderr_path = File.join(repo, "stderr.log")
      env = {
        "PATH" => "#{bin_dir}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH', '')}",
        "HARNEX_AUTOSTOP_TEARDOWN_GRACE_SECONDS" => "1"
      }

      pid = spawn(
        env,
        Gem.ruby, "-I#{File.expand_path('../../../lib', __dir__)}", File.expand_path("../../../bin/harnex", __dir__),
        "run", "codex",
        "--id", id,
        "--context", "finish quickly",
        "--auto-stop",
        "--summary-out", summary_path,
        chdir: repo,
        pgroup: true,
        out: stdout_path,
        err: stderr_path
      )

      status = wait_for_child(pid, timeout: 10.0)
      assert status, "harnex run did not exit; stderr=#{File.exist?(stderr_path) ? File.read(stderr_path) : ''}"
      assert_equal 0, status.exitstatus, "stderr=#{File.exist?(stderr_path) ? File.read(stderr_path) : ''}"
      assert File.exist?(summary_path), "summary row was not written"

      row = JSON.parse(File.readlines(summary_path).last)
      assert_equal id, row.dig("meta", "id")
      assert_equal true, row.dig("actual", "task_complete")

      with_env("PATH" => env["PATH"]) do
        out, = capture_io { assert_equal 0, Harnex::Doctor.new(["--sweep"]).run }
        sweep = JSON.parse(out).fetch("sweep")
        assert_empty sweep.fetch("harnex_sessions").select { |session| session["id"] == id }
        assert_empty sweep.fetch("orphan_tmux").select { |window| [window["session"], window["window"]].include?(id) }
      end
    ensure
      terminate_process_group(pid) if pid
    end
  end

  def test_usage_documents_summary_out
    assert_includes Harnex::Runner.usage, "--summary-out PATH"
  end

  def test_usage_documents_artifact_report
    assert_includes Harnex::Runner.usage, "--artifact-report PATH"
    assert_includes Harnex::Runner.usage, "--validation-report PATH"
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

  def test_telemetry_flags_override_meta_regardless_of_order
    argv = [
      "codex",
      "--project-id", "harnex",
      "--queue-id", "queue-005",
      "--entry-id=SP-4",
      "--phase", "implement",
      "--intent", "queue-work",
      "--model", "gpt-test",
      "--effort=high",
      "--meta", '{"project_id":"old","phase":"old","intent":"old","model":"old"}'
    ]
    runner = Harnex::Runner.new(argv)
    runner.send(:extract_wrapper_options, argv)
    runner.send(:apply_telemetry_options!)
    meta = runner.instance_variable_get(:@options)[:meta]

    assert_equal "harnex", meta.fetch("project_id")
    assert_equal "queue-005", meta.fetch("queue_id")
    assert_equal "SP-4", meta.fetch("entry_id")
    assert_equal "implement", meta.fetch("phase")
    assert_equal "queue-work", meta.fetch("intent")
    assert_equal "gpt-test", meta.fetch("model")
    assert_equal "high", meta.fetch("effort")
  end

  def test_attempt_linkage_flags_override_meta_and_validate_kind
    argv = [
      "codex", "--parent-dispatch-id", "dispatch-1", "--parent-attempt-id=attempt-1",
      "--attempt-kind", "retry", "--meta", '{"attempt_kind":"bad","parent_attempt_id":"old"}'
    ]
    runner = Harnex::Runner.new(argv)
    runner.send(:extract_wrapper_options, argv)
    runner.send(:apply_telemetry_options!)
    runner.send(:validate_attempt_metadata!)
    meta = runner.instance_variable_get(:@options).fetch(:meta)

    assert_equal "dispatch-1", meta.fetch("parent_dispatch_id")
    assert_equal "attempt-1", meta.fetch("parent_attempt_id")
    assert_equal "retry", meta.fetch("attempt_kind")

    invalid = Harnex::Runner.new(["codex", "--attempt-kind", "unknown"])
    invalid.send(:extract_wrapper_options, ["codex", "--attempt-kind", "unknown"])
    invalid.send(:apply_telemetry_options!)
    error = assert_raises(OptionParser::InvalidOption) { invalid.send(:validate_attempt_metadata!) }
    assert_match(/--attempt-kind must be one of/, error.message)
  end

  def test_require_attribution_rejects_missing_fields
    runner = Harnex::Runner.new(["codex", "--require-attribution", "--project-id", "harnex", "--phase", "implement"])
    runner.send(:extract_wrapper_options, ["codex", "--require-attribution", "--project-id", "harnex", "--phase", "implement"])
    runner.send(:apply_telemetry_options!)

    error = assert_raises(OptionParser::InvalidOption) { runner.send(:validate_required_attribution!) }

    assert_match(/--require-attribution missing/, error.message)
    assert_match(/intent/, error.message)
    assert_match(/one of queue_id\/entry_id\/issue\/plan/, error.message)
  end

  def test_require_attribution_accepts_complete_metadata
    runner = Harnex::Runner.new([
      "codex", "--require-attribution", "--project-id", "harnex",
      "--phase", "implement", "--intent", "queue-work", "--entry-id", "SP-4"
    ])
    runner.send(:extract_wrapper_options, [
      "codex", "--require-attribution", "--project-id", "harnex",
      "--phase", "implement", "--intent", "queue-work", "--entry-id", "SP-4"
    ])
    runner.send(:apply_telemetry_options!)

    runner.send(:validate_required_attribution!)
  end

  def test_extract_wrapper_options_parses_summary_out
    runner = Harnex::Runner.new(["codex", "--summary-out", "tmp/dispatch.jsonl"])
    cli_name, forwarded = runner.send(:extract_wrapper_options, ["codex", "--summary-out", "tmp/dispatch.jsonl"])
    opts = runner.instance_variable_get(:@options)

    assert_equal "codex", cli_name
    assert_equal [], forwarded
    assert_equal "tmp/dispatch.jsonl", opts[:summary_out]
  end

  def test_extract_wrapper_options_parses_artifact_report
    runner = Harnex::Runner.new(["codex", "--artifact-report", "tmp/report.json"])
    cli_name, forwarded = runner.send(:extract_wrapper_options, ["codex", "--artifact-report", "tmp/report.json"])
    opts = runner.instance_variable_get(:@options)

    assert_equal "codex", cli_name
    assert_equal [], forwarded
    assert_equal "tmp/report.json", opts[:artifact_report]
  end

  def test_extract_wrapper_options_parses_validation_report_alias
    runner = Harnex::Runner.new(["codex", "--validation-report=tmp/validation.json"])
    runner.send(:extract_wrapper_options, ["codex", "--validation-report=tmp/validation.json"])

    assert_equal "tmp/validation.json", runner.instance_variable_get(:@options)[:artifact_report]
  end

  def test_resolve_summary_out_defaults_to_dot_harnex_when_koder_dir_exists
    Dir.mktmpdir("harnex-summary-repo") do |repo|
      FileUtils.mkdir_p(File.join(repo, "koder"))
      runner = Harnex::Runner.new(["codex"])

      assert_equal File.join(repo, ".harnex", "dispatch.jsonl"), runner.send(:resolve_summary_out, repo)
    end
  end

  def test_resolve_summary_out_defaults_to_dot_harnex_without_koder_dir
    Dir.mktmpdir("harnex-summary-repo") do |repo|
      runner = Harnex::Runner.new(["codex"])

      assert_equal File.join(repo, ".harnex", "dispatch.jsonl"), runner.send(:resolve_summary_out, repo)
    end
  end

  def test_resolve_summary_out_expands_explicit_path
    Dir.mktmpdir("harnex-summary-repo") do |repo|
      runner = Harnex::Runner.new(["codex", "--summary-out", "tmp/dispatch.jsonl"])
      runner.send(:extract_wrapper_options, ["codex", "--summary-out", "tmp/dispatch.jsonl"])

      assert_equal File.join(repo, "tmp", "dispatch.jsonl"), runner.send(:resolve_summary_out, repo)
    end
  end

  def test_resolve_artifact_report_expands_path_and_creates_parent
    Dir.mktmpdir("harnex-artifact-report-repo") do |repo|
      runner = Harnex::Runner.new(["codex", "--artifact-report", "reports/worker.json"])
      runner.send(:extract_wrapper_options, ["codex", "--artifact-report", "reports/worker.json"])

      path = runner.send(:resolve_artifact_report, repo)

      assert_equal File.join(repo, "reports", "worker.json"), path
      assert_path_exists File.join(repo, "reports")
    end
  end

  def test_extract_wrapper_options_parses_cwd_before_cli
    Dir.mktmpdir("harnex-run-cwd") do |cwd|
      runner = Harnex::Runner.new(["--cwd", cwd, "codex"])
      cli_name, forwarded = runner.send(:extract_wrapper_options, ["--cwd", cwd, "codex"])
      opts = runner.instance_variable_get(:@options)

      assert_equal "codex", cli_name
      assert_equal [], forwarded
      assert_equal cwd, opts[:cwd]
    end
  end

  def test_extract_wrapper_options_rejects_missing_cwd_directory
    missing = File.join(Dir.tmpdir, "harnex-missing-cwd-#{$$}")
    runner = Harnex::Runner.new(["codex", "--cwd", missing])

    error = assert_raises(OptionParser::InvalidArgument) do
      runner.send(:extract_wrapper_options, ["codex", "--cwd", missing])
    end

    assert_match(/--cwd must be an existing directory/, error.message)
  end

  def test_run_cwd_is_authoritative_over_child_cd_passthrough
    Dir.mktmpdir("harnex-run-cwd") do |root|
      cwd = File.join(root, "bundle")
      child_cd = File.join(root, "child-cd")
      FileUtils.mkdir_p([cwd, child_cd])
      runner = Harnex::Runner.new(["codex", "--cwd", cwd, "--", "--cd", child_cd])
      cli_name, forwarded = runner.send(:extract_wrapper_options, ["codex", "--cwd", cwd, "--", "--cd", child_cd])

      assert_equal "codex", cli_name
      assert_equal ["--cd", child_cd], forwarded
      assert_equal cwd, runner.send(:resolve_run_root, cli_name, forwarded)
    end
  end

  def test_run_cwd_uses_non_git_directory_for_child_root_and_default_summary
    Dir.mktmpdir("harnex-run-cwd") do |root|
      launch = File.join(root, "orchestrator")
      bundle = File.join(root, "bundle")
      FileUtils.mkdir_p([launch, bundle])
      result_path = File.join(root, "cwd.json")
      id = "cwd-nongit-#{$$}"

      Dir.chdir(launch) do
        _out, err = capture_io do
          assert_equal 0, Harnex::Runner.new([
            RbConfig.ruby,
            "--id", id,
            "--cwd", bundle,
            "--", "-e", cwd_probe_script, result_path
          ]).run
        end
        refute_match(/fatal: not a git repository/, err)
      end

      payload = JSON.parse(File.read(result_path))
      assert_equal bundle, payload.fetch("pwd")
      assert_equal bundle, payload.fetch("repo_root")

      summary_path = File.join(bundle, ".harnex", "dispatch.jsonl")
      assert_path_exists summary_path
      row = JSON.parse(File.readlines(summary_path, chomp: true).last)
      assert_equal id, row.dig("meta", "id")
      assert_equal bundle, row.dig("meta", "repo")
      assert_equal 0, row.dig("actual", "exit_code")
    end
  end

  def test_run_cwd_accepts_git_directory
    Dir.mktmpdir("harnex-run-cwd-git") do |root|
      launch = File.join(root, "orchestrator")
      repo = File.join(root, "repo")
      FileUtils.mkdir_p([launch, repo])
      assert system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      result_path = File.join(root, "cwd.json")
      id = "cwd-git-#{$$}"

      Dir.chdir(launch) do
        _out, err = capture_io do
          assert_equal 0, Harnex::Runner.new([
            RbConfig.ruby,
            "--id", id,
            "--cwd", repo,
            "--", "-e", cwd_probe_script, result_path
          ]).run
        end
        refute_match(/fatal:/, err)
      end

      payload = JSON.parse(File.read(result_path))
      assert_equal repo, payload.fetch("pwd")
      assert_equal repo, payload.fetch("repo_root")
      assert_path_exists File.join(repo, ".harnex", "dispatch.jsonl")
    end
  end

  def test_run_cwd_expands_relative_directory_from_invocation_cwd
    Dir.mktmpdir("harnex-run-relative-cwd") do |launch|
      bundle = File.join(launch, "bundle")
      FileUtils.mkdir_p(bundle)
      result_path = File.join(launch, "cwd.json")

      Dir.chdir(launch) do
        capture_io do
          assert_equal 0, Harnex::Runner.new([
            RbConfig.ruby,
            "--id", "cwd-relative-#{$$}",
            "--cwd", "bundle",
            "--", "-e", cwd_probe_script, result_path
          ]).run
        end
      end

      payload = JSON.parse(File.read(result_path))
      assert_equal bundle, payload.fetch("pwd")
      assert_equal bundle, payload.fetch("repo_root")
    end
  end

  def test_run_cwd_resolves_explicit_summary_out_relative_to_selected_root
    Dir.mktmpdir("harnex-run-summary-cwd") do |root|
      launch = File.join(root, "orchestrator")
      bundle = File.join(root, "bundle")
      FileUtils.mkdir_p([launch, bundle])
      result_path = File.join(root, "cwd.json")
      id = "cwd-summary-#{$$}"

      Dir.chdir(launch) do
        capture_io do
          assert_equal 0, Harnex::Runner.new([
            RbConfig.ruby,
            "--id", id,
            "--cwd", bundle,
            "--summary-out", "reports/dispatch.jsonl",
            "--", "-e", cwd_probe_script, result_path
          ]).run
        end
      end

      summary_path = File.join(bundle, "reports", "dispatch.jsonl")
      assert_path_exists summary_path
      refute_path_exists File.join(launch, "reports", "dispatch.jsonl")
      row = JSON.parse(File.readlines(summary_path, chomp: true).last)
      assert_equal bundle, row.dig("meta", "repo")
    end
  end

  def test_run_root_overrides_metadata_without_changing_child_cwd
    Dir.mktmpdir("harnex-run-root") do |root|
      launch = File.join(root, "orchestrator")
      attributed_root = File.join(root, "attributed")
      FileUtils.mkdir_p([launch, attributed_root])
      result_path = File.join(root, "cwd.json")
      id = "root-split-#{$$}"

      Dir.chdir(launch) do
        capture_io do
          assert_equal 0, Harnex::Runner.new([
            RbConfig.ruby,
            "--id", id,
            "--root", attributed_root,
            "--", "-e", cwd_probe_script, result_path
          ]).run
        end
      end

      payload = JSON.parse(File.read(result_path))
      assert_equal launch, payload.fetch("pwd")
      assert_equal attributed_root, payload.fetch("repo_root")
      assert_path_exists File.join(attributed_root, ".harnex", "dispatch.jsonl")
    end
  end

  def test_run_artifact_report_exposes_env_and_writes_summary_blocks
    Dir.mktmpdir("harnex-run-artifact-report") do |repo|
      summary_path = File.join(repo, "summary.jsonl")
      env_path = File.join(repo, "env.json")
      id = "artifact-valid-#{$$}"

      Dir.chdir(repo) do
        capture_io do
          assert_equal 0, Harnex::Runner.new([
            RbConfig.ruby,
            "--id", id,
            "--artifact-report", ".harnex/reports/#{id}.json",
            "--summary-out", summary_path,
            "--", "-e", artifact_report_writer_script, env_path
          ]).run
        end
      end

      report_path = File.join(repo, ".harnex", "reports", "#{id}.json")
      env_payload = JSON.parse(File.read(env_path))
      assert_equal report_path, env_payload.fetch("artifact_report_path")
      assert_equal report_path, env_payload.fetch("validation_report_path")
      assert_equal Harnex::ArtifactReport::SCHEMA, env_payload.fetch("schema")

      row = JSON.parse(File.readlines(summary_path, chomp: true).last)
      assert_equal "ok", row.dig("artifact_report", "ingest_status")
      assert_equal Harnex::ArtifactReport::SCHEMA, row.dig("artifact_report", "schema")
      assert_equal "pass", row.dig("artifact_report", "report_status")
      assert_equal report_path, row.dig("artifact_report", "path")
      assert_equal File.size(report_path), row.dig("artifact_report", "bytes")
      assert_match(/\A[0-9a-f]{64}\z/, row.dig("artifact_report", "sha256"))
      assert_equal ["koder/issues/52_typed_artifact_validation_sidecars.md"], row.dig("artifact_report", "canonical_artifacts")
      assert_equal "pass", row.dig("validation", "status")
      assert_equal true, row.dig("validation", "final_reported")
      assert_equal "ruby -c lib/harnex/artifact_report.rb", row.dig("validation", "commands", 0, "cmd")
      assert_equal 0, row.dig("validation", "commands", 0, "exit_code")
      assert_equal "gate", row.dig("artifacts", 0, "type")
      assert_equal "Sidecar report emitted.", row.dig("artifacts", 0, "summary")
    end
  end

  def test_run_artifact_report_missing_file_records_warning_without_crashing
    Dir.mktmpdir("harnex-run-artifact-missing") do |repo|
      summary_path = File.join(repo, "summary.jsonl")
      id = "artifact-missing-#{$$}"

      Dir.chdir(repo) do
        capture_io do
          assert_equal 0, Harnex::Runner.new([
            RbConfig.ruby,
            "--id", id,
            "--artifact-report", ".harnex/reports/#{id}.json",
            "--summary-out", summary_path,
            "--", "-e", "exit 0"
          ]).run
        end
      end

      row = JSON.parse(File.readlines(summary_path, chomp: true).last)
      assert_equal "missing", row.dig("artifact_report", "ingest_status")
      assert_match(/not found/, row.dig("artifact_report", "warning"))
      refute row.key?("validation")
      refute row.key?("artifacts")
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

  def test_tmux_rejects_unknown_double_dash_flag
    runner = Harnex::Runner.new(["codex", "--tmux", "--name", "cx-p-322"])

    error = assert_raises(OptionParser::InvalidOption) do
      runner.send(:extract_wrapper_options, ["codex", "--tmux", "--name", "cx-p-322"])
    end

    assert_match(/--name/, error.message)
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

  def cwd_probe_script
    <<~'RUBY'
      require "json"

      File.write(ARGV.fetch(0), JSON.generate(
        "pwd" => Dir.pwd,
        "repo_root" => ENV["HARNEX_SESSION_REPO_ROOT"],
        "argv" => ARGV.drop(1)
      ))
    RUBY
  end

  def artifact_report_writer_script
    <<~'RUBY'
      require "json"

      report_path = ENV.fetch("HARNEX_ARTIFACT_REPORT_PATH")
      File.write(ARGV.fetch(0), JSON.generate(
        "artifact_report_path" => report_path,
        "validation_report_path" => ENV["HARNEX_VALIDATION_REPORT_PATH"],
        "schema" => ENV["HARNEX_ARTIFACT_REPORT_SCHEMA"]
      ))
      File.write(report_path, JSON.generate(
        "schema" => ENV.fetch("HARNEX_ARTIFACT_REPORT_SCHEMA"),
        "status" => "pass",
        "canonical_artifacts" => ["koder/issues/52_typed_artifact_validation_sidecars.md"],
        "validation" => {
          "status" => "pass",
          "final_reported" => true,
          "commands" => [
            { "cmd" => "ruby -c lib/harnex/artifact_report.rb", "exit_code" => 0 }
          ]
        },
        "artifacts" => [
          {
            "type" => "gate",
            "summary" => "Sidecar report emitted.",
            "evidence" => ["HARNEX_ARTIFACT_REPORT_PATH"],
            "confidence" => 1.0,
            "canonical_ref" => "koder/issues/52_typed_artifact_validation_sidecars.md"
          }
        ]
      ))
    RUBY
  end

  def write_hanging_interrupt_codex_stub(path)
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"

      if ARGV == ["--version"]
        puts "codex 0.128.0"
        exit 0
      end

      abort "expected app-server" unless ARGV.first == "app-server"

      STDOUT.sync = true

      STDIN.each_line do |line|
        msg = JSON.parse(line)
        case msg["method"]
        when "initialize"
          puts JSON.generate(jsonrpc: "2.0", id: msg["id"], result: {})
        when "initialized"
          nil
        when "thread/start"
          puts JSON.generate(jsonrpc: "2.0", id: msg["id"], result: { thread: { id: "thr-test" } })
        when "turn/start"
          puts JSON.generate(jsonrpc: "2.0", id: msg["id"], result: { turn: { id: "trn-test" } })
          puts JSON.generate(jsonrpc: "2.0", method: "turn/completed", params: {
            thread: { id: "thr-test" },
            turn: { id: "trn-test", status: "completed" }
          })
        when "turn/interrupt"
          loop { sleep 1 }
        end
      end
    RUBY
    File.chmod(0o755, path)
  end

  def assert_codex_service_tier_argv(wrapper_args, expected_tier)
    Dir.mktmpdir("harnex-service-tier-run") do |repo|
      bin_dir = File.join(repo, "bin")
      FileUtils.mkdir_p(bin_dir)
      write_service_tier_codex_stub(File.join(bin_dir, "codex"))

      argv_path = File.join(repo, "argv.json")
      summary_path = File.join(repo, "DISPATCH.jsonl")
      env = {
        "PATH" => "#{bin_dir}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH', '')}",
        "HARNEX_STUB_ARGV_PATH" => argv_path,
        "HARNEX_AUTOSTOP_TEARDOWN_GRACE_SECONDS" => "1"
      }

      _stdout, stderr, status = Open3.capture3(
        env,
        Gem.ruby, "-I#{File.expand_path('../../../lib', __dir__)}", File.expand_path("../../../bin/harnex", __dir__),
        "run", "codex", *wrapper_args,
        "--id", "service-tier-#{expected_tier}-#{$$}",
        "--context", "finish quickly",
        "--auto-stop",
        "--summary-out", summary_path,
        chdir: repo
      )

      assert status.success?, stderr
      assert_equal ["app-server", "-c", "service_tier=\"#{expected_tier}\""], JSON.parse(File.read(argv_path))
    end
  end

  def write_service_tier_codex_stub(path)
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"

      if ARGV == ["--version"]
        puts "codex 0.128.0"
        exit 0
      end

      File.write(ENV.fetch("HARNEX_STUB_ARGV_PATH"), JSON.generate(ARGV))
      abort "expected app-server" unless ARGV.first == "app-server"

      STDOUT.sync = true

      STDIN.each_line do |line|
        msg = JSON.parse(line)
        case msg["method"]
        when "initialize"
          puts JSON.generate(jsonrpc: "2.0", id: msg["id"], result: {})
        when "initialized"
          nil
        when "thread/start"
          puts JSON.generate(jsonrpc: "2.0", id: msg["id"], result: { thread: { id: "thr-tier" } })
        when "turn/start"
          puts JSON.generate(jsonrpc: "2.0", id: msg["id"], result: { turn: { id: "trn-tier" } })
          puts JSON.generate(jsonrpc: "2.0", method: "turn/started", params: {
            thread: { id: "thr-tier" },
            turn: { id: "trn-tier", status: "in_progress" }
          })
          puts JSON.generate(jsonrpc: "2.0", method: "turn/completed", params: {
            thread: { id: "thr-tier" },
            turn: { id: "trn-tier", status: "completed" },
            tokenUsage: {
              total: {
                inputTokens: 1,
                outputTokens: 1,
                reasoningOutputTokens: 0,
                cachedInputTokens: 0,
                totalTokens: 2
              }
            }
          })
        when "turn/interrupt"
          puts JSON.generate(jsonrpc: "2.0", id: msg["id"], result: {})
          exit 0
        end
      end
    RUBY
    File.chmod(0o755, path)
  end

  def wait_for_child(pid, timeout:)
    deadline = Time.now + timeout
    loop do
      waited = Process.waitpid2(pid, Process::WNOHANG)
      return waited[1] if waited
      return nil if Time.now >= deadline

      sleep 0.05
    end
  rescue Errno::ECHILD
    nil
  end

  def terminate_process_group(pid)
    Process.kill("TERM", -pid)
    sleep 0.2
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    begin
      Process.waitpid(pid, Process::WNOHANG)
    rescue Errno::ECHILD
      nil
    end
  end
end
