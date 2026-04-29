require "json"
require "rbconfig"

require_relative "../../test_helper"

class EventsCommandTest < Minitest::Test
  def setup
    @repo_root = Dir.mktmpdir("harnex-events-repo")
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
    events = Harnex::Events.new(["--help"])
    assert_output(/Usage: harnex events/) { assert_equal 0, events.run }
  end

  def test_returns_1_when_no_session_or_stream_exists
    events = Harnex::Events.new(["--id", "missing", "--repo", @repo_root, "--snapshot"])
    assert_output(nil, /no session or event stream found/) { assert_equal 1, events.run }
  end

  def test_snapshot_outputs_existing_events_in_order
    id = "snapshot-session"
    rows = [
      event_row(id, 1, "started", "2026-04-29T10:00:00Z", "pid" => 10_001),
      event_row(id, 2, "send", "2026-04-29T10:00:01Z", "msg" => "build", "msg_truncated" => false, "forced" => false),
      event_row(id, 3, "exited", "2026-04-29T10:00:02Z", "code" => 0)
    ]
    path = write_events(id, rows)

    events = Harnex::Events.new(["--id", id, "--repo", @repo_root, "--snapshot"])
    out, = capture_io { assert_equal 0, events.run }

    assert_equal File.read(path), out
  end

  def test_default_follow_prints_snapshot_and_exits_when_session_already_exited
    id = "done-session"
    rows = [
      event_row(id, 1, "started", "2026-04-29T10:00:00Z", "pid" => 10_100),
      event_row(id, 2, "exited", "2026-04-29T10:00:05Z", "code" => 0)
    ]
    write_events(id, rows)

    events = Harnex::Events.new(["--id", id, "--repo", @repo_root])
    out, = capture_io { assert_equal 0, events.run }

    assert_equal 2, out.lines.length
    assert_equal %w[started exited], out.lines.map { |line| JSON.parse(line)["type"] }
  end

  def test_follow_streams_until_exited_event
    id = "follow-session"
    path = write_events(id, [
      event_row(id, 1, "started", "2026-04-29T10:00:00Z", "pid" => 20_001)
    ])

    pid = spawn_detached_sleep(2.0)
    @pids << pid
    write_registry(id, pid: pid)

    appender = Thread.new do
      sleep 0.2
      append_event(path, event_row(id, 2, "send", "2026-04-29T10:00:01Z", "msg" => "continue", "msg_truncated" => false, "forced" => true))
      sleep 0.2
      append_event(path, event_row(id, 3, "exited", "2026-04-29T10:00:02Z", "code" => 0))
    end

    events = Harnex::Events.new(["--id", id, "--repo", @repo_root])
    out, = capture_io { assert_equal 0, events.run }

    appender.join(1)
    parsed = out.lines.map { |line| JSON.parse(line) }
    assert_equal %w[started send exited], parsed.map { |row| row["type"] }
  end

  def test_from_filters_snapshot_events
    id = "from-session"
    write_events(id, [
      event_row(id, 1, "started", "2026-04-29T10:00:00Z", "pid" => 30_001),
      event_row(id, 2, "send", "2026-04-29T10:00:05Z", "msg" => "later", "msg_truncated" => false, "forced" => false),
      event_row(id, 3, "exited", "2026-04-29T10:00:10Z", "code" => 0)
    ])

    events = Harnex::Events.new(["--id", id, "--repo", @repo_root, "--snapshot", "--from", "2026-04-29T10:00:05Z"])
    out, = capture_io { assert_equal 0, events.run }

    parsed = out.lines.map { |line| JSON.parse(line) }
    assert_equal %w[send exited], parsed.map { |row| row["type"] }
  end

  def test_follow_exits_non_zero_when_stream_is_truncated
    id = "truncated-session"
    path = write_events(id, [
      event_row(id, 1, "started", "2026-04-29T10:00:00Z", "pid" => 40_001)
    ])

    pid = spawn_detached_sleep(2.0)
    @pids << pid
    write_registry(id, pid: pid)

    truncater = Thread.new do
      sleep 0.2
      File.truncate(path, 0)
    end

    events = Harnex::Events.new(["--id", id, "--repo", @repo_root])
    assert_output(nil, /stream source was truncated/) { assert_equal 1, events.run }
    truncater.join(1)
  end

  def test_fixture_matches_v1_schema_contract
    fixture_path = File.expand_path("../../fixtures/events_v1.jsonl", __dir__)
    rows = File.readlines(fixture_path, chomp: true).map { |line| JSON.parse(line) }

    refute_empty rows
    assert_equal rows.length, rows.map { |row| row["seq"] }.uniq.length
    assert_equal((1..rows.length).to_a, rows.map { |row| row["seq"] })

    rows.each do |row|
      assert_equal 1, row["schema_version"]
      assert_kind_of String, row["ts"]
      assert_kind_of String, row["id"]
      assert_kind_of String, row["type"]
    end

    type_map = rows.to_h { |row| [row.fetch("type"), row] }
    assert type_map.key?("started")
    assert type_map.key?("send")
    assert type_map.key?("exited")

    assert_kind_of Integer, type_map.fetch("started").fetch("pid")
    assert_kind_of String, type_map.fetch("send").fetch("msg")
    assert_includes [true, false], type_map.fetch("send").fetch("msg_truncated")
    assert_includes [true, false], type_map.fetch("send").fetch("forced")
    assert_kind_of Integer, type_map.fetch("exited").fetch("code")
  end

  private

  def event_row(id, seq, type, ts, payload = {})
    {
      "schema_version" => 1,
      "seq" => seq,
      "ts" => ts,
      "id" => id,
      "type" => type
    }.merge(payload)
  end

  def write_registry(id, pid: Process.pid, cli: "codex")
    path = Harnex.registry_path(@repo_root, id)
    Harnex.write_registry(path, {
      "id" => id,
      "cli" => cli,
      "pid" => pid,
      "host" => "127.0.0.1",
      "port" => 43_000 + @paths.length,
      "repo_root" => @repo_root,
      "events_log_path" => Harnex.events_log_path(@repo_root, id),
      "started_at" => Time.now.iso8601
    })
    @paths << path
    path
  end

  def write_events(id, rows)
    path = Harnex.events_log_path(@repo_root, id)
    File.open(path, "wb") do |file|
      rows.each do |row|
        file.write(JSON.generate(row))
        file.write("\n")
      end
    end
    @paths << path
    path
  end

  def append_event(path, row)
    File.open(path, "ab") do |file|
      file.write(JSON.generate(row))
      file.write("\n")
      file.flush
    end
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
