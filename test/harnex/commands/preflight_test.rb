require_relative "../../test_helper"
require "open3"
require "shellwords"

# #56: preflight drives the real `harnex run` path against a stub Codex
# app-server that follows the preflight prompt (or misbehaves on purpose).
class PreflightTest < Minitest::Test
  LIB = File.expand_path("../../../lib", __dir__)
  BIN = File.expand_path("../../../bin/harnex", __dir__)

  def setup
    @root = Dir.mktmpdir("harnex-preflight-test")
    @repo = File.join(@root, "repo")
    @task_root = File.join(@root, "tasks")
    @bin = File.join(@root, "bin")
    FileUtils.mkdir_p([@repo, @task_root, @bin])
    git(@repo, "init", "-q")
    git(@repo, "commit", "-q", "--allow-empty", "-m", "base")
    write_obedient_codex_stub(File.join(@bin, "codex"))
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_obedient_adapter_passes_every_check_and_cleans_up
    verdict, code = preflight

    assert_equal 0, code, verdict.inspect
    assert_equal true, verdict["ok"]
    assert_nil verdict["failure"]
    statuses = verdict["checks"].to_h { |item| [item["name"], item["status"]] }
    Harnex::Preflight::CHECKS.each { |name| assert_equal "pass", statuses[name], "#{name}: #{verdict['checks']}" }
    assert_equal "completed_with_proof", verdict["outcome_class"]
    assert_equal %w[context cost cost_source usage], verdict["telemetry"].keys.sort

    row = dispatch_rows.last
    assert_equal "preflight", row.dig("meta", "phase")
    assert_equal verdict["id"], row["id"]
    assert_empty Dir.children(@task_root), "task file is removed"
    refute File.exist?(File.join(@repo, ".harnex", "preflight")), "workspace probe file is removed"
  end

  def test_workspace_write_denial_is_its_own_failing_check
    verdict, code = preflight(mode: "skip_write")

    assert_equal 1, code
    assert_equal "workspace_write_denied", verdict["failure"]
    assert_equal "fail", status_of(verdict, "workspace_write")
    assert_equal "skipped", status_of(verdict, "task_read")
  end

  def test_unreadable_task_file_is_its_own_failing_check
    verdict, = preflight(mode: "wrong_token")

    assert_equal "task_read_denied", verdict["failure"]
    assert_equal "pass", status_of(verdict, "workspace_write")
  end

  def test_missing_claims_fail_the_claims_check
    verdict, = preflight(mode: "no_claims")

    assert_equal "claims_missing", verdict["failure"]
    assert_equal "pass", status_of(verdict, "receipt")
  end

  def test_turn_that_fails_before_any_work_names_the_root_cause_and_redacts_it
    verdict, code = preflight(mode: "auth_fail")

    assert_equal 1, code
    assert_equal "task_failed", verdict["failure"]
    %w[task_read workspace_write command_exit receipt claims].each { |name| assert_equal "skipped", status_of(verdict, name) }
    completion = verdict["checks"].find { |item| item["name"] == "completion" }
    assert_includes completion["detail"], "401 Unauthorized"
    refute_includes completion["detail"], "abcd1234"
    assert_equal "pass", status_of(verdict, "stop")
  end

  def test_hanging_turn_times_out_and_is_stopped
    verdict, code = preflight(mode: "hang", extra: ["--timeout", "3"])

    assert_equal 1, code
    assert_equal "timeout", verdict["failure"]
    assert_equal "fail", status_of(verdict, "stop")
    assert_equal "skipped", status_of(verdict, "workspace_write"), "a timeout is not blamed on the workspace"
    assert_includes verdict["checks"].find { |item| item["name"] == "stop" }["detail"], "did not finish"
    assert_nil Harnex.read_registry(@repo, verdict["id"]), "the stuck worker is stopped"
  end

  # `harnex stop --repo` resolves the Git top-level, but `run --cwd DIR`
  # registers under DIR: the stop must still reach a worker in a subdirectory.
  def test_hanging_turn_in_a_repo_subdirectory_is_still_stopped
    subdir = File.join(@repo, "pkg", "inner")
    FileUtils.mkdir_p(subdir)
    verdict, = preflight(mode: "hang", cwd: subdir, extra: ["--timeout", "3"])

    assert_equal "timeout", verdict["failure"]
    assert_nil Harnex.read_registry(subdir, verdict["id"]), "the stuck worker in the subdirectory is stopped"
  end

  def test_reserved_preflight_phase_passes_a_rejecting_repo_phase_policy
    FileUtils.mkdir_p(File.join(@repo, ".harnex"))
    File.write(File.join(@repo, ".harnex", "config.json"),
               JSON.generate(phase: { allowlist: %w[implement review], policy: "reject" }))
    verdict, code = preflight

    assert_equal 0, code, verdict.inspect
  end

  def test_launch_errors_are_not_reported_as_registration_timeouts
    FileUtils.mkdir_p(File.join(@repo, ".harnex"))
    File.write(File.join(@repo, ".harnex", "config.json"), JSON.generate(phase: { allowlist: ["x"], policy: "nope" }))
    verdict, code = preflight

    assert_equal 1, code
    assert_equal "launch_failed", verdict["failure"]
    assert_includes verdict["checks"].first["detail"], "invalid config"
  end

  def test_missing_adapter_binary_fails_launch_without_running_later_checks
    verdict, code = preflight(adapter: "definitely-not-an-agent-cli", extra: ["--registration-timeout", "2"])

    assert_equal 1, code
    assert_equal "launch_failed", verdict["failure"]
    assert_equal "fail", status_of(verdict, "registration")
    assert_equal "skipped", status_of(verdict, "completion")
    assert_equal({ "usage" => "unavailable", "cost" => "unavailable", "context" => "unavailable" }, verdict["telemetry"])
  end

  def test_commit_check_proves_a_commit_in_a_scratch_repo_only
    caller_head = git(@repo, "rev-parse", "HEAD")
    verdict, code = preflight(extra: ["--commit-check"])

    assert_equal 0, code, verdict.inspect
    assert_equal "pass", status_of(verdict, "commit")
    assert_equal caller_head, git(@repo, "rev-parse", "HEAD"), "caller repo is never committed to"
  end

  def test_usage_errors
    assert_raises(OptionParser::MissingArgument) { Harnex::Preflight.new([], out: StringIO.new).run }
    assert_raises(OptionParser::InvalidOption) { Harnex::Preflight.new(%w[codex --bogus], out: StringIO.new).run }
    out = StringIO.new
    assert_equal 0, Harnex::Preflight.new(["--help"], out: out).run
    assert_includes out.string, "harnex preflight ADAPTER"
  end

  def test_orchestration_report_excludes_preflight_rows_unless_asked
    rows = [
      { "meta" => { "id" => "w1", "phase" => "preflight" }, "queue" => { "queue_id" => "q" },
        "orchestration" => { "role" => "worker" }, "outcome" => { "class" => "boot_failure" } },
      { "meta" => { "id" => "w2" }, "queue" => { "queue_id" => "q" },
        "orchestration" => { "role" => "worker" }, "outcome" => { "class" => "completed_with_proof" } }
    ]
    default = Harnex::Orchestration.build_report(dispatch_rows: rows, sample_rows: [], queue_id: "q")
    included = Harnex::Orchestration.build_report(dispatch_rows: rows, sample_rows: [], queue_id: "q", include_preflight: true)

    assert_equal 1, default.dig("workers", "dispatches")
    assert_equal 2, included.dig("workers", "dispatches")
  end

  private

  def preflight(adapter: "codex", mode: "obey", extra: [], cwd: @repo, child: [])
    env = {
      "PATH" => "#{@bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH', '')}",
      "HARNEX_STUB_MODE" => mode,
      "HARNEX_AUTOSTOP_TEARDOWN_GRACE_SECONDS" => "1",
      "GIT_AUTHOR_NAME" => "harnex-test", "GIT_AUTHOR_EMAIL" => "test@localhost",
      "GIT_COMMITTER_NAME" => "harnex-test", "GIT_COMMITTER_EMAIL" => "test@localhost"
    }
    with_env(env) do
      out = StringIO.new
      code = Harnex::Preflight.new(
        [adapter, "--cwd", cwd, "--task-root", @task_root, *extra, *(child.empty? ? [] : ["--", *child])],
        out: out, harnex_command: [Gem.ruby, "-I#{LIB}", BIN]
      ).run
      [JSON.parse(out.string), code]
    end
  end

  def status_of(verdict, name)
    verdict["checks"].find { |item| item["name"] == name }&.fetch("status")
  end

  def dispatch_rows
    File.readlines(Harnex::DispatchHistory.path_for(@repo)).map { |line| JSON.parse(line) }
        .select { |row| row["record_type"] == "dispatch_end" }
  end

  def with_env(overrides)
    saved = overrides.keys.to_h { |key| [key, ENV[key]] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def git(dir, *args)
    out, err, status = Open3.capture3(
      { "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@localhost",
        "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@localhost" },
      "git", "-C", dir, *args
    )
    raise err unless status.success?

    out.strip
  end

  # Follows the numbered preflight prompt like a compliant model would, and
  # reports each shell command the way Codex does: wrapped in `bash -lc`.
  def write_obedient_codex_stub(path)
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      require "fileutils"
      require "json"
      require "shellwords"
      if ARGV == ["--version"]; puts "codex 0.147.0"; exit 0; end
      abort "expected app-server" unless ARGV.first == "app-server"
      STDOUT.sync = true
      mode = ENV.fetch("HARNEX_STUB_MODE", "obey")
      emit = ->(payload) { puts JSON.generate(payload.merge(jsonrpc: "2.0")) }
      STDIN.each_line do |line|
        msg = JSON.parse(line)
        case msg["method"]
        when "initialize" then emit.call(id: msg["id"], result: {})
        when "thread/start" then emit.call(id: msg["id"], result: { thread: { id: "thr-pf" } })
        when "turn/start"
          emit.call(id: msg["id"], result: { turn: { id: "trn-pf" } })
          next if mode == "hang"

          # A real turn takes seconds; an instant one would finish (and
          # auto-stop) before `harnex run --detach` polls the registry.
          sleep 1
          if mode == "auth_fail"
            emit.call(method: "turn/completed", params: { thread: { id: "thr-pf" }, turn: {
              id: "trn-pf", status: "failed",
              error: { message: "unexpected status 401 Unauthorized: Incorrect API key provided: sk-proj-****abcd1234" }
            } })
            next
          end

          text = msg.dig("params", "input", 0, "text").to_s
          task = text[/Read the task file: (.+)$/, 1]
          out = text[/, to: (.+)$/, 1]
          token = File.read(task).strip rescue nil
          token = "not-the-token" if mode == "wrong_token"
          if out && mode != "skip_write"
            FileUtils.mkdir_p(File.dirname(out))
            File.write(out, "#{token}\n")
          end
          text.scan(/Run this exact shell command: (.+)$/).flatten.each_with_index do |command, index|
            next if mode == "no_claims" && command.include?("HARNEX_ARTIFACT_CLAIMS_PATH")

            system("sh", "-c", command, out: File::NULL)
            emit.call(method: "item/completed", params: { item: {
              id: "cmd-#{index}", type: "commandExecution", status: "completed",
              command: Shellwords.join(["/bin/bash", "-lc", command]), exitCode: $?.exitstatus
            } })
          end
          emit.call(method: "turn/completed", params: { thread: { id: "thr-pf" }, turn: { id: "trn-pf", status: "completed" } })
        when "turn/interrupt"
          emit.call(id: msg["id"], result: {}); exit 0
        end
      end
    RUBY
    File.chmod(0o755, path)
  end
end
