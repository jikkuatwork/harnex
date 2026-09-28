require_relative "../../test_helper"
require "rbconfig"

class RuntimeBudgetProcessTest < Minitest::Test
  def setup
    @repo = Dir.mktmpdir("harnex-runtime-process")
    system("git", "init", "-q", @repo, out: File::NULL, err: File::NULL)
    @bin = File.join(@repo, "bin")
    FileUtils.mkdir_p(@bin)
    File.write(File.join(@bin, "pi"), pi_fixture)
    File.chmod(0o755, File.join(@bin, "pi"))
    @cli = File.expand_path("../../../bin/harnex", __dir__)
    @lib = File.expand_path("../../../lib", __dir__)
  end

  def teardown
    FileUtils.rm_rf(@repo)
  end

  def test_runtime_expiry_ignores_ui_chatter_without_an_observer
    status, row = run_fixture("chatter")
    assert_equal 124, status.exitstatus
    assert_equal "runtime_budget", row.dig("stop", "reason")
    assert_equal "runtime", row.dig("stop", "origin")
    assert_equal "rejected", row.dig("outcome", "status")
    assert_equal 0, row.dig("reliability", "real_disconnections")
    events = File.readlines(row.fetch("events_log_path")).map { |line| JSON.parse(line) }
    assert events.any? { |event| event["type"] == "extension_ui_request" }
    assert_equal 1, events.count { |event| event["type"] == "stop_requested" }
    assert_equal 1, events.count { |event| event["type"] == "completion_notification" }
    report = JSON.parse(File.read(row.dig("artifact_report", "path")))
    assert_equal "runtime_budget", report.dig("observed", "stop", "reason")
    refute report.dig("observed", "turn", "accepted")
  end

  def test_runtime_expiry_preempts_a_prompt_request_that_never_answers
    status, row = run_fixture("no_ack")
    assert_equal 124, status.exitstatus
    assert_equal "runtime_budget", row.dig("stop", "reason")
    assert_equal "rejected", row.dig("outcome", "status")
    assert_equal 0, row.dig("reliability", "real_disconnections")
  end

  def test_expiry_after_settlement_preserves_accepted_work
    status, row = run_fixture("settled")
    assert_equal 0, status.exitstatus
    assert_equal "completed", row["status"]
    assert_equal "completed", row.dig("stop", "work_state")
    assert_equal "runtime_budget", row.dig("stop", "reason")
    assert Harnex::ArtifactReport.validate(row.dig("artifact_report", "path"), final: true).ok
  end

  def test_pty_runtime_budget_escalates_if_term_is_ignored
    status, row = run_case(
      [RbConfig.ruby, "--max-runtime", "0.15s", "--", "-e", 'trap("TERM") {}; loop { sleep 1 }']
    )
    assert_equal 124, status.exitstatus
    assert_equal "runtime_budget", row.dig("stop", "reason")
    assert_equal "unknown", row.dig("activity", "status")
    assert_nil row.dig("activity", "last_model_activity_at")
    assert_equal "rejected", row.dig("outcome", "status")
  end

  def run_fixture(mode)
    run_case(["pi", "--max-runtime", "0.4s", "--context", "synthetic task"], "HARNEX_FIXTURE_MODE" => mode)
  end

  def run_case(args, extra_env = {})
    id = "runtime-#{SecureRandom.hex(4)}"
    out = File.join(@repo, "stdout.log")
    err = File.join(@repo, "stderr.log")
    env = { "PATH" => "#{@bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}" }.merge(extra_env)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    pid = spawn(env, Gem.ruby, "-I#{@lib}", @cli, "run", "--id", id, *args,
                chdir: @repo, pgroup: true, out: out, err: err)
    status = Timeout.timeout(8) do
      loop do
        result = Process.wait2(pid, Process::WNOHANG)
        break result.last if result

        sleep 0.01
      end
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 5.0, File.read(err)
    rows = File.readlines(Harnex::DispatchHistory.path_for(@repo)).map { |line| JSON.parse(line) }
    terminal = rows.select { |row| row["id"] == id && row["record_type"] == "dispatch_end" }
    assert_equal 1, terminal.length, File.read(err)
    start_row = rows.find { |row| row["id"] == id && row["record_type"] == "dispatch_start" }
    refute Harnex.alive_pid?(start_row.fetch("pid")), "runtime child survived termination"
    assert_nil Harnex.read_registry(@repo, id)
    [status, terminal.first]
  ensure
    begin
      Process.kill("KILL", -pid) if pid
    rescue Errno::ESRCH
      nil
    end
    begin
      Process.waitpid(pid) if pid
    rescue Errno::ECHILD
      nil
    end
  end

  def pi_fixture
    <<~'RUBY'
      #!/usr/bin/env ruby
      require "json"
      if ARGV.include?("--version")
        puts "0.87.1"
        exit
      end
      STDOUT.sync = true
      mutex = Mutex.new
      send_record = ->(record) { mutex.synchronize { puts JSON.generate(record) } }
      STDIN.each_line do |line|
        command = JSON.parse(line)
        type = command["type"]
        next if type == "abort" # budget must not depend on an abort response
        unless type == "prompt" && ENV["HARNEX_FIXTURE_MODE"] == "no_ack"
          send_record.call(type: "response", command: type, id: command["id"], success: true, data: {})
        end
        next unless type == "prompt"
        send_record.call(type: "agent_start")
        send_record.call(type: "turn_start")
        send_record.call(type: "message_start", message: { role: "assistant", content: [] })
        if ENV["HARNEX_FIXTURE_MODE"] == "settled"
          message = { role: "assistant", content: [], stopReason: "stop" }
          send_record.call(type: "message_end", message: message)
          send_record.call(type: "agent_end", messages: [message], willRetry: false)
          send_record.call(type: "agent_settled")
        end
        Thread.new do
          loop do
            send_record.call(type: "extension_ui_request", method: "setStatus", statusText: "chatter")
            sleep 0.01
          end
        end
      end
    RUBY
  end
end
