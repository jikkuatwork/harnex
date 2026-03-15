require "rbconfig"

require_relative "../../test_helper"

class LogsCommandTest < Minitest::Test
  def setup
    @repo_root = Dir.mktmpdir("harnex-logs-repo")
    system("git", "init", "-q", @repo_root, out: File::NULL, err: File::NULL)
    @paths = []
    @pids = []
  end

  def teardown
    @paths.each { |path| FileUtils.rm_f(path) }
    @pids.each do |pid|
      begin
        Process.kill("TERM", pid)
      rescue Errno::ESRCH
        nil
      end
    end
    FileUtils.rm_rf(@repo_root)
  end

  def test_help_returns_zero
    logs = Harnex::Logs.new(["--help"])
    assert_output(/Usage: harnex logs/) { assert_equal 0, logs.run }
  end

  def test_returns_1_when_no_session_or_transcript_exists
    logs = Harnex::Logs.new(["--id", "missing", "--repo", @repo_root])
    assert_output(nil, /no session or transcript found/) { assert_equal 1, logs.run }
  end

  def test_returns_1_when_active_session_transcript_is_missing
    write_registry("live-session")

    logs = Harnex::Logs.new(["--id", "live-session", "--repo", @repo_root])
    assert_output(nil, /transcript not found/) { assert_equal 1, logs.run }
  end

  def test_snapshot_outputs_last_lines_from_existing_transcript
    write_transcript("snapshot-session", "one\ntwo\nthree\n")

    logs = Harnex::Logs.new(["--id", "snapshot-session", "--repo", @repo_root, "--lines", "2"])
    out, = capture_io { assert_equal 0, logs.run }

    assert_equal "two\nthree\n", out
  end

  def test_follow_streams_bytes_appended_after_startup
    id = "follow-session"
    path = write_transcript(id, "start\n")
    pid = spawn_detached_sleep(0.6)
    @pids << pid
    write_registry(id, pid: pid)

    appender = Thread.new do
      sleep 0.2
      File.open(path, "ab") do |file|
        file.write("more\n")
        file.flush
      end
    end

    logs = Harnex::Logs.new(["--id", id, "--repo", @repo_root, "--follow", "--lines", "1"])
    out, = capture_io { assert_equal 0, logs.run }

    appender.join(1)
    assert_equal "start\nmore\n", out
  end

  def test_exited_session_falls_back_to_repo_scoped_transcript
    write_transcript("exited-session", "persisted output\n")

    logs = Harnex::Logs.new(["--id", "exited-session", "--repo", @repo_root])
    out, = capture_io { assert_equal 0, logs.run }

    assert_equal "persisted output\n", out
  end

  private

  def write_registry(id, pid: Process.pid, cli: "codex")
    path = Harnex.registry_path(@repo_root, id)
    Harnex.write_registry(path, {
      "id" => id,
      "cli" => cli,
      "pid" => pid,
      "host" => "127.0.0.1",
      "port" => 43_000 + @paths.length,
      "repo_root" => @repo_root,
      "started_at" => Time.now.iso8601
    })
    @paths << path
    path
  end

  def write_transcript(id, contents)
    path = Harnex.output_log_path(@repo_root, id)
    File.binwrite(path, contents)
    @paths << path
    path
  end

  def spawn_detached_sleep(seconds)
    launcher = IO.popen([RbConfig.ruby, "-e", <<~RUBY, seconds.to_s], "r")
      seconds = Float(ARGV.fetch(0))
      pid = fork do
        STDIN.reopen("/dev/null")
        STDOUT.reopen("/dev/null", "a")
        STDERR.reopen("/dev/null", "a")
        sleep seconds
      end
      puts pid
      STDOUT.flush
      exit! 0
    RUBY

    pid = Integer(launcher.read.strip)
    launcher.close
    pid
  end
end
