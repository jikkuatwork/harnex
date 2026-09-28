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

  def test_runtime_budget_survives_an_earlier_advisory_manual_stop
    status, row = run_case(
      [RbConfig.ruby, "--max-runtime", "0.6s", "--", "-e", 'trap("TERM") {}; loop { sleep 1 }']
    ) do |_pid, id|
      registry = Timeout.timeout(3) do
        loop do
          row = Harnex.read_registry(@repo, id)
          break row if row
          sleep 0.01
        end
      end
      uri = URI("http://#{registry.fetch('host')}:#{registry.fetch('port')}/stop")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{registry.fetch('token')}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(reason: "manual", origin: "cli")
      response = Net::HTTP.start(uri.host, uri.port, read_timeout: 1) { |http| http.request(request) }
      assert_equal "200", response.code
    end
    assert_equal 124, status.exitstatus
    assert_equal "manual", row.dig("stop", "reason"), "first stop provenance must remain immutable"
    assert_equal true, row.dig("runtime_budget", "enforced")
  end

  def test_runtime_budget_includes_codex_initialize_handshake
    File.write(File.join(@bin, "codex"), <<~'RUBY')
      #!/usr/bin/env ruby
      if ARGV.include?("--version")
        puts "0.147.0"
        exit
      end
      File.write("child.pid", Process.pid.to_s)
      STDIN.each_line { |line| File.write("initialize.request", line); sleep 60 }
    RUBY
    File.chmod(0o755, File.join(@bin, "codex"))
    status, row = run_case(["codex", "--max-runtime", "0.3s", "--context", "test"])
    assert File.file?(File.join(@repo, "initialize.request")), "must reach real handshake"
    assert_equal 124, status.exitstatus
    assert_equal "runtime_budget", row.dig("stop", "reason")
    assert_equal "rejected", row.dig("outcome", "status")
  end

  def test_runtime_budget_terminates_a_worker_descendant
    status, row = run_fixture("descendant")
    assert_equal 124, status.exitstatus
    child = Integer(File.read(File.join(@repo, "grandchild.pid")))
    refute executing?(child), "tool descendant is still executing after runner exit"
    assert_equal true, row.dig("runtime_budget", "enforced")
  ensure
    Process.kill("KILL", child) if child && executing?(child)
  end

  def test_physical_budget_is_independent_of_runner_stdout_backpressure
    reader, writer = IO.pipe
    err = File.join(@repo, "blocked-output.err")
    env = { "PATH" => "#{@bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}", "HARNEX_FIXTURE_MODE" => "pipe" }
    pid = spawn(env, Gem.ruby, "-I#{@lib}", @cli, "run", "pi", "--id", "blocked-output",
                "--max-runtime", "0.4s", "--context", "test", chdir: @repo,
                pgroup: true, out: writer, err: err)
    writer.close
    child = Timeout.timeout(2) do
      loop do
        path = File.join(@repo, "child.pid")
        break Integer(File.read(path)) if File.file?(path)
        sleep 0.01
      end
    end
    child_group = Process.getpgid(child)
    sleep 1.2
    alive = executing?(child)
    drain = Thread.new { reader.read }
    status = Timeout.timeout(5) { Process.wait2(pid).last }
    refute alive, "full runner stdout delayed physical worker termination"
    assert_equal 124, status.exitstatus, File.read(err)
  ensure
    Process.kill("KILL", -child_group) if child_group && child_group != Process.getpgrp rescue nil
    Process.kill("KILL", -pid) if pid rescue nil
    Process.waitpid(pid) if pid rescue nil
    drain&.join(1)
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end

  def executing?(pid)
    return false unless Harnex.alive_pid?(pid)
    stat = "/proc/#{pid}/stat"
    return true unless File.file?(stat)

    File.read(stat).split(") ", 2).last.split.first != "Z"
  rescue Errno::ENOENT
    false
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
    yield(pid, id) if block_given?
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
    registry = Harnex.read_registry(@repo, id) if id
    child_pid = registry && registry["pid"]
    child_file = File.join(@repo, "child.pid")
    child_pid ||= Integer(File.read(child_file)) if File.file?(child_file)
    if child_pid && Harnex.alive_pid?(child_pid)
      group = Process.getpgid(child_pid) rescue nil
      Process.kill("KILL", -group) if group && group != Process.getpgrp rescue nil
      reap_process(child_pid)
    end
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
      File.write("child.pid", Process.pid.to_s)
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
        if ENV["HARNEX_FIXTURE_MODE"] == "pipe"
          send_record.call(type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "x" * 2_000_000 })
        elsif ENV["HARNEX_FIXTURE_MODE"] == "descendant"
          child = spawn("ruby", "-e", 'trap("TERM") {}; loop { sleep 1 }', in: File::NULL, out: File::NULL, err: File::NULL)
          File.write("grandchild.pid", child.to_s)
        end
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
