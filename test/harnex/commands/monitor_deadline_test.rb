require_relative "../../test_helper"
require "open3"
require "rbconfig"
require "stringio"

class MonitorDeadlineTest < Minitest::Test
  def setup
    @repo = Dir.mktmpdir("harnex-monitor-deadline")
    @id = "monitor-#{$$}"
    @events = Harnex.events_log_path(@repo, @id)
    @registry = Harnex.registry_path(@repo, @id)
    @exit_path = Harnex.exit_status_path(@repo, @id)
    File.write(@events, JSON.generate(type: "started", seq: 7) + "\n")
    Harnex.write_registry(@registry, {
      "id" => @id, "pid" => Process.pid, "host" => "127.0.0.1", "port" => 9,
      "repo_root" => @repo, "started_at" => Time.now.iso8601
    })
  end

  def teardown
    [@events, @registry, @exit_path].each { |path| FileUtils.rm_f(path) }
    FileUtils.rm_rf(@repo)
  end

  def test_slow_live_session_is_bounded_and_probe_is_reaped
    assert_slow_probe_bounded(:live_session)
  end

  def test_slow_scan_cannot_publish_late_completion
    assert_slow_probe_bounded(:scan_events)
  end

  def test_slow_status_probe_is_bounded_despite_standard_error_rescue
    assert_slow_probe_bounded(:fetch_agent_state, until_state: "prompt")
  end

  def test_slow_initial_registry_probe_is_bounded
    waiter = build_waiter
    started = monotonic
    out, = capture_io do
      Harnex.stub(:read_registry, ->(*) { sleep 0.6; nil }) do
        assert_equal 124, waiter.run
      end
    end
    assert_timeout(out, started)
  end

  def test_exit_status_grace_is_inside_the_cap
    waiter = build_waiter(until_state: nil)
    out, = capture_io do
      Harnex.stub(:read_registry, { "pid" => 123_456 }) do
        Harnex.stub(:alive_pid?, false) do
          started = monotonic
          assert_equal 124, waiter.run
          assert_operator monotonic - started, :<, 0.4
        end
      end
    end
    assert_equal "timeout", JSON.parse(out)["status"]
  end

  def test_done_post_exit_resolution_is_inside_the_cap
    waiter = build_waiter
    calls = 0
    waiter.define_singleton_method(:live_session) do |_repo|
      calls += 1
      calls == 1 ? { "pid" => 123_456 } : nil
    end
    started = monotonic
    out, = capture_io { assert_equal 124, waiter.run }
    assert_timeout(out, started)
  end

  def test_http_read_is_bounded_and_socket_is_closed
    server = TCPServer.new("127.0.0.1", 0)
    Harnex.write_registry(@registry, {
      "id" => @id, "pid" => Process.pid, "host" => "127.0.0.1", "port" => server.addr[1],
      "repo_root" => @repo
    })
    waiter = build_waiter(until_state: "prompt", timeout: "0.2")
    started = monotonic
    out, = capture_io { assert_equal 124, waiter.run }
    assert_operator monotonic - started, :<, 0.5
    assert_equal "timeout", JSON.parse(out)["status"]
    assert IO.select([server], nil, nil, 0.5), "observer must actually connect to HTTP"
    client = server.accept
    received = +""
    deadline = monotonic + 0.5
    loop do
      chunk = client.read_nonblock(4096, exception: false)
      break if chunk.nil?
      received << chunk unless chunk == :wait_readable
      flunk "observer left HTTP socket open" if monotonic >= deadline
      IO.select([client], nil, nil, 0.01) if chunk == :wait_readable
    end
    assert_includes received, "GET /status"
  ensure
    client&.close
    server&.close
  end

  def test_timeout_alias_accepts_durations_and_preserves_live_worker
    waiter = Harnex::Waiter.new(["--repo", @repo, "--id", @id, "--until", "done", "--max-wait", "0.12s"])
    out, err = capture_io { assert_equal 124, waiter.run }
    assert_equal "timeout", JSON.parse(out)["wait_result"]
    assert_empty err
    assert Harnex.alive_pid?(Process.pid)
    assert File.exist?(@registry)
  end

  def test_finite_positive_durations_required_by_both_commands
    invalid = ["0", "-1", "NaN", "Infinity", "1e999", "9" * 400 + "h"]
    [Harnex::Waiter, Harnex::WatchCommand].each do |klass|
      %w[--heartbeat --timeout --max-wait].each do |option|
        invalid.each do |value|
          command = klass.new(["--id", @id, option, value])
          assert_raises(OptionParser::InvalidArgument, "#{klass} #{option} #{value}") { command.run }
        end
      end
    end
  end

  def test_positive_float_timeout_syntax_remains_compatible
    %w[.12 1.2e-1].each do |duration|
      waiter = build_waiter(timeout: duration)
      out, = capture_io { assert_equal 124, waiter.run }
      assert_equal "timeout", JSON.parse(out)["status"]
    end
  end

  def test_large_but_finite_duration_does_not_overflow_select_timeout
    File.write(@events, JSON.generate(type: "task_complete", seq: 8) + "\n")
    out, = capture_io { assert_equal 0, build_waiter(timeout: "9" * 300).run }
    assert_equal "task_complete", JSON.parse(out)["event"]
  end

  def test_typed_results_and_raw_exit_code_survive_the_observer_boundary
    [["task_complete", nil, 0], ["task_failed", "failed", 1],
     ["task_failed", "report_rejected", 2]].each do |type, outcome, expected|
      File.write(@events, JSON.generate(type: type, seq: 8, outcome_class: outcome) + "\n")
      out, err = capture_io { assert_equal expected, build_waiter(timeout: "1").run }
      assert_equal 1, out.lines.length
      assert_equal type, JSON.parse(out)["event"]
      assert_empty err
    end

    FileUtils.rm_f([@events, @registry])
    out, = capture_io { assert_equal 3, build_waiter(timeout: "1").run }
    assert_equal "no_such_session", JSON.parse(out)["wait_result"]

    File.write(@exit_path, JSON.generate(id: @id, exit_code: 143, signal: 15))
    out, = capture_io { assert_equal 143, build_waiter(until_state: nil, timeout: "1").run }
    assert_equal 143, JSON.parse(out)["exit_code"]
  end

  def test_heartbeat_is_opt_in_and_reports_observed_state_not_log_age
    File.write(@events, JSON.generate(type: "agent_state", state: "busy", seq: 9, log_idle_s: 0) + "\n")
    out, err = capture_io { assert_equal 124, build_waiter.run }
    assert_empty err
    assert_equal "running", JSON.parse(out)["work_state"]

    out, err = capture_io do
      assert_equal 124, Harnex::Waiter.new([
        "--repo", @repo, "--id", @id, "--until", "done", "--timeout", "0.12", "--heartbeat", "0.04s"
      ]).run
    end
    assert_match(/state=busy last_event=agent_state seq=9/, err)
    refute_match(/log_idle|model|tool|progress_age/, err)
    assert_equal 1, out.lines.length
  end

  def test_parent_error_cancels_probe_without_leaking_child_or_thread
    probe_pid_path = File.join(@repo, "probe.pid")
    err = StringIO.new
    err.define_singleton_method(:flush) { raise IOError, "closed diagnostic sink" }
    waiter = Harnex::Waiter.new([
      "--repo", @repo, "--id", @id, "--until", "done", "--heartbeat", "0.08s"
    ], out: StringIO.new, err: err)
    waiter.define_singleton_method(:live_session) do |*|
      File.write(probe_pid_path, Process.pid.to_s)
      begin
        sleep 3
      ensure
        sleep 3
      end
    end
    threads = Thread.list
    started = monotonic
    assert_raises(IOError) { waiter.run }
    assert_operator monotonic - started, :<, 0.4
    assert_empty Thread.list - threads
    probe_pid = Integer(File.read(probe_pid_path))
    assert_raises(Errno::ECHILD) { Process.waitpid(probe_pid, Process::WNOHANG) }
    assert_raises(Errno::ESRCH) { Process.kill(0, probe_pid) }
  end

  def test_wall_clock_jumps_do_not_control_deadline_or_waited_seconds
    # Event waits avoid wall-clock session freshness, which intentionally uses
    # event timestamps. Their elapsed time must not use Time.now at all.
    clock = Time.now
    Harnex.stub(:resolve_repo_root, @repo) do
      Time.stub(:now, -> { clock += 3600 }) do
        started = monotonic
        out, = capture_io { assert_equal 124, build_waiter(until_state: "task_complete").run }
        assert_timeout(out, started)
        assert_in_delta 0.12, JSON.parse(out)["waited_seconds"], 0.1
      end
    end
  end

  def test_terminal_watcher_does_not_replace_global_streams
    out = StringIO.new
    err = StringIO.new
    original_out = $stdout
    original_err = $stderr
    constructor = Harnex::Waiter.method(:new)
    factory = lambda do |argv, **streams|
      assert_same original_out, $stdout
      assert_same original_err, $stderr
      assert streams[:out], "wait must receive an explicit output stream"
      assert_same err, streams[:err]
      constructor.call(argv, **streams)
    end
    File.write(@events, JSON.generate(type: "task_complete", seq: 8) + "\n")
    Harnex::Waiter.stub(:new, factory) do
      assert_equal 0, Harnex::TerminalWatcher.new(id: @id, repo_path: @repo, out: out, err: err).run
    end
    assert_equal 1, out.string.lines.length
    assert_equal "done", JSON.parse(out.string)["wait_result"]
  end

  def test_watcher_timeout_never_stops_or_writes_markers
    done_marker = File.join(@repo, "done.json")
    fail_marker = File.join(@repo, "fail.json")
    out = StringIO.new
    watcher = Harnex::TerminalWatcher.new(
      id: @id, repo_path: @repo, max_wait: 0.12, done_marker: done_marker,
      fail_marker: fail_marker, stop_on_terminal: true, out: out, err: StringIO.new
    )
    watcher.define_singleton_method(:stop_session) { raise "timeout must not stop worker" }
    assert_equal 124, watcher.run
    assert_equal "timeout", JSON.parse(out.string)["status"]
    refute File.exist?(done_marker)
    refute File.exist?(fail_marker)
    assert Harnex.alive_pid?(Process.pid)
  end

  def test_real_process_deadline_preempts_slow_probe_and_slow_ensure
    probe_pid_path = File.join(@repo, "probe.pid")
    code = <<~RUBY
      require "harnex"
      class Harnex::Waiter
        def live_session(*)
          File.write(#{probe_pid_path.inspect}, Process.pid.to_s)
          begin
            sleep 3
          rescue StandardError
            retry
          ensure
            sleep 3
          end
        end
      end
      exit Harnex::Waiter.new(ARGV).run
    RUBY
    started = monotonic
    with_command(RbConfig.ruby, "-Ilib", "-e", code, "--", "--repo", @repo,
                 "--id", @id, "--until", "done", "--timeout", "0.2") do |stdout, stderr, process|
      assert process.join(1.0), "monitor process overran its cap"
      elapsed = monotonic - started
      assert_equal 124, process.value.exitstatus, stderr.read
      assert_operator elapsed, :<, 0.8, "cap + event poll + 0.5s startup/scheduling tolerance"
      assert_equal "timeout", JSON.parse(stdout.read)["status"]
      probe_pid = Integer(File.read(probe_pid_path))
      assert_raises(Errno::ESRCH) { Process.kill(0, probe_pid) }
    end
  end

  def test_watch_heartbeat_is_flushed_before_completion_with_one_json_stdout
    with_command(RbConfig.ruby, "-Ilib", "bin/harnex", "watch", "--repo", @repo,
                 "--id", @id, "--heartbeat", "0.05s", "--max-wait", "3s") do |stdout, stderr, process|
      deadline = monotonic + 1.0
      loop do
        remaining = deadline - monotonic
        assert remaining.positive? && IO.select([stderr], nil, nil, remaining),
               "observed heartbeat was not flushed before completion"
        line = stderr.gets
        refute_nil line
        # Repo discovery may still be pending on the very first heartbeat.
        break if line.match?(/waited=.*state=running.*last_event=started.*seq=7/)
      end
      assert process.alive?, "heartbeat arrived only after process exit"
      refute IO.select([stdout], nil, nil, 0), "stdout must remain final JSON only"
      File.open(@events, "a") { |file| file.puts JSON.generate(type: "task_complete", seq: 8) }
      assert process.join(1.0)
      assert_equal 0, process.value.exitstatus, stderr.read
      output = stdout.read
      assert_equal 1, output.lines.length
      assert_equal "task_complete", JSON.parse(output)["event"]
    end
  end

  def test_heartbeat_continues_during_a_slow_probe_without_claiming_work_progress
    code = <<~RUBY
      require "harnex"
      class Harnex::Waiter
        def live_session(*)
          sleep 3
        end
      end
      exit Harnex::Waiter.new(ARGV).run
    RUBY
    with_command(RbConfig.ruby, "-Ilib", "-e", code, "--", "--repo", @repo,
                 "--id", @id, "--until", "done", "--heartbeat", "0.05s", "--timeout", "0.3") do |stdout, stderr, process|
      assert IO.select([stderr], nil, nil, 1.0)
      line = stderr.gets
      assert_match(/state=unknown.*last_event=unknown.*seq=unknown/, line)
      assert process.alive?
      assert process.join(1.0)
      assert_equal 124, process.value.exitstatus
      assert_equal "timeout", JSON.parse(stdout.read)["status"]
      assert_operator stderr.read.lines.length, :>=, 1
    end
  end

  private

  def build_waiter(until_state: "done", timeout: "0.12")
    argv = ["--repo", @repo, "--id", @id, "--timeout", timeout]
    argv += ["--until", until_state] if until_state
    Harnex::Waiter.new(argv)
  end

  def assert_slow_probe_bounded(method, until_state: "done")
    waiter = build_waiter(until_state: until_state)
    probe_pid_path = File.join(@repo, "probe.pid")
    waiter.define_singleton_method(method) do |*args, **kwargs|
      File.write(probe_pid_path, Process.pid.to_s)
      begin
        sleep 0.6
        if method == :scan_events
          [emit_event_match({ "type" => "task_complete" }, args[4], "done"), 0, false]
        end
      rescue StandardError
        retry
      end
    end
    threads = Thread.list
    started = monotonic
    out, = capture_io { assert_equal 124, waiter.run }
    assert_timeout(out, started)
    assert_empty Thread.list - threads, "monitor leaked a thread"
    probe_pid = Integer(File.read(probe_pid_path))
    refute_equal Process.pid, probe_pid
    assert_raises(Errno::ECHILD) { Process.waitpid(probe_pid, Process::WNOHANG) }
    assert_raises(Errno::ESRCH) { Process.kill(0, probe_pid) }
  end

  def assert_timeout(out, started)
    assert_operator monotonic - started, :<, 0.4
    assert_equal 1, out.lines.length
    payload = JSON.parse(out)
    assert_equal "timeout", payload["status"]
    refute payload["ok"]
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def with_command(*argv)
    Open3.popen3(*argv, chdir: File.expand_path("../../..", __dir__)) do |stdin, stdout, stderr, process|
      stdin.close
      begin
        yield stdout, stderr, process
      ensure
        Process.kill("KILL", process.pid) if process.alive?
        process.join(1)
      end
    end
  end
end
