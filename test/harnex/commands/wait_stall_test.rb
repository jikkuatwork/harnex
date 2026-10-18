require_relative "../../test_helper"
require "securerandom"
require "socket"
require "stringio"

# #76: `wait/watch --until done --stall-after` against a fake live status API.
class WaitStallTest < Minitest::Test
  def setup
    @repo = Dir.mktmpdir("harnex-wait-stall")
    system("git", "init", "-q", @repo, out: File::NULL, err: File::NULL)
    @id = "stall-worker-#{SecureRandom.hex(3)}"
    @worker = spawn("sleep", "30")
    @requests = Queue.new
    @payload = structured_payload(idle: 90.0)
    start_status_server
    Harnex.write_registry(Harnex.registry_path(@repo, @id), {
      "id" => @id, "pid" => @worker, "host" => "127.0.0.1", "port" => @port,
      "token" => "t", "started_at" => Time.now.iso8601, "repo_root" => @repo
    })
  end

  def teardown
    @server&.close
    reap_thread(@server_thread)
    reap_process(@worker)
    FileUtils.rm_f(Harnex.registry_path(@repo, @id))
    FileUtils.rm_rf(@repo)
  end

  def structured_payload(idle:)
    {
      "ok" => true, "work_state" => "running", "done" => false, "log_idle_s" => 1,
      "activity" => {
        "status" => "observed", "source" => "pi_rpc", "turn_active" => true, "model_active" => true,
        "turn_age_s" => idle + 50, "model_idle_s" => idle, "tool_idle_s" => idle + 20
      }
    }
  end

  def start_status_server
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @server_thread = Thread.new do
      loop do
        client = @server.accept
        request_line = client.gets("\r\n").to_s
        while (line = client.gets("\r\n"))
          break if line.strip.empty?
        end
        @requests << request_line.split[0, 2].join(" ")
        body = JSON.generate(@payload)
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      rescue IOError, Errno::EBADF
        break
      end
    end
  end

  def requests
    list = []
    list << @requests.pop until @requests.empty?
    list
  end

  def test_no_progress_past_the_threshold_exits_4_and_leaves_the_worker_running
    out, err = capture_io do
      assert_equal 4, Harnex::Waiter.new(["--repo", @repo, "--id", @id, "--until", "done", "--stall-after", "60"]).run
    end

    payload = JSON.parse(out)
    assert_equal "stalled", payload["status"]
    assert_equal "stalled", payload["wait_result"]
    assert_equal "running", payload["work_state"]
    assert_equal({ "clock" => "activity", "idle_s" => 90.0, "threshold_s" => 60.0 }, payload["stall"])
    assert_includes err, "worker left running"
    assert Harnex.alive_pid?(@worker)
    refute_includes requests, "POST /stop"
  end

  def test_progress_below_the_threshold_keeps_waiting_for_done
    events = Harnex.events_log_path(@repo, @id)
    FileUtils.mkdir_p(File.dirname(events))
    writer = Thread.new do
      sleep 0.8
      File.write(events, JSON.generate(schema_version: 1, seq: 1, ts: Time.now.utc.iso8601(3), id: @id, type: "task_complete") + "\n")
    end

    out, = capture_io do
      assert_equal 0, Harnex::Waiter.new(["--repo", @repo, "--id", @id, "--until", "done", "--stall-after", "1h"]).run
    end

    assert_equal "task_complete", JSON.parse(out)["event"]
    assert_includes requests, "GET /status", "the stall clock was consulted"
  ensure
    reap_thread(writer)
    FileUtils.rm_f(events) if events
  end

  def test_pty_session_uses_the_output_log_clock
    @payload = { "ok" => true, "work_state" => "running", "log_idle_s" => 120, "activity" => { "status" => "unknown" } }

    out, = capture_io do
      assert_equal 4, Harnex::Waiter.new(["--repo", @repo, "--id", @id, "--until", "done", "--stall-after", "100"]).run
    end

    assert_equal "output_log", JSON.parse(out).dig("stall", "clock")
  end

  def test_stall_after_requires_until_done
    assert_raises(OptionParser::InvalidOption) do
      Harnex::Waiter.new(["--id", @id, "--until", "task_complete", "--stall-after", "60"]).run
    end
  end

  def test_watch_stall_writes_no_marker_and_skips_stop_on_terminal
    marker = File.join(@repo, "failed.json")
    out = StringIO.new
    err = StringIO.new
    watcher = Harnex::TerminalWatcher.new(
      id: @id, repo_path: @repo, stall_after: 60.0, max_wait: 30,
      fail_marker: marker, stop_on_terminal: true, out: out, err: err
    )

    assert_equal 4, watcher.run
    assert_equal "stalled", JSON.parse(out.string)["status"]
    refute File.exist?(marker), "a stall is not a failure verdict"
    refute_includes requests, "POST /stop"
    assert Harnex.alive_pid?(@worker)
  end

  def test_watch_command_parses_stall_after
    command = Harnex::WatchCommand.new(["--id", @id, "--repo", @repo, "--stall-after", "1m"])
    command.send(:parser).parse!(command.instance_variable_get(:@argv))

    assert_equal 60.0, command.instance_variable_get(:@options)[:stall_after]
  end
end
