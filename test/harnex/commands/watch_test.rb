require_relative "../../test_helper"
require "stringio"

class RunWatcherTest < Minitest::Test
  def setup
    @repo_root = Dir.pwd
    @registry_paths = []
  end

  def teardown
    @registry_paths.each { |path| FileUtils.rm_f(path) }
  end

  def test_run_exits_zero_when_session_exits_without_resume
    id = "watch-happy-#{$$}"
    statuses = [
      { "ok" => true, "agent_state" => "busy", "log_idle_s" => 10 },
      { "ok" => true, "agent_state" => "busy", "log_idle_s" => 15 },
      { "ok" => true, "agent_state" => "exited", "log_idle_s" => 15 }
    ]

    with_watch_server(statuses: statuses) do |port, sends|
      write_registry(id, port)
      watcher, out, err = build_watcher(id, stall_after_s: 120, max_resumes: 1)

      assert_equal 0, watcher.run
      assert_equal [], sends
      assert_includes out.string, "outcome=exited"
      assert_empty err.string
    end
  end

  def test_run_sends_forced_resume_then_exits_zero
    id = "watch-resume-#{$$}"
    statuses = [
      { "ok" => true, "agent_state" => "busy", "log_idle_s" => 600 },
      { "ok" => true, "agent_state" => "exited", "log_idle_s" => 1 }
    ]

    with_watch_server(statuses: statuses) do |port, sends|
      write_registry(id, port)
      watcher, out, err = build_watcher(id, stall_after_s: 300, max_resumes: 1)

      assert_equal 0, watcher.run
      assert_equal 1, sends.length
      assert_equal "resume", sends.first["text"]
      assert_equal true, sends.first["force"]
      assert_equal true, sends.first["submit"]
      assert_includes out.string, "resume 1/1"
      assert_includes out.string, "outcome=exited"
      assert_empty err.string
    end
  end

  def test_run_escalates_when_resume_cap_reached
    id = "watch-escalate-#{$$}"
    statuses = [
      { "ok" => true, "agent_state" => "busy", "log_idle_s" => 600 },
      { "ok" => true, "agent_state" => "busy", "log_idle_s" => 601 }
    ]

    with_watch_server(statuses: statuses) do |port, sends|
      write_registry(id, port)
      watcher, out, err = build_watcher(id, stall_after_s: 300, max_resumes: 1)

      assert_equal 2, watcher.run
      assert_equal 1, sends.length
      assert_includes out.string, "max resumes reached, escalating"
      assert_includes out.string, "outcome=escalated"
      assert_empty err.string
    end
  end

  def test_terminal_watch_succeeds_on_task_complete_and_writes_done_marker
    Dir.mktmpdir("harnex-terminal-watch-success") do |repo|
      system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      id = "watch-done-#{$$}"
      marker = File.join(repo, "done.json")
      write_terminal_event(repo, id, type: "task_complete", seq: 2)

      out = StringIO.new
      err = StringIO.new
      watcher = Harnex::TerminalWatcher.new(id: id, repo_path: repo, done_marker: marker, out: out, err: err)
      assert_equal 0, watcher.run

      payload = JSON.parse(out.string)
      assert payload["ok"]
      assert_equal true, payload["done"]
      assert_equal "completed", payload["work_state"]
      assert_equal "task_complete", payload["event"]
      assert_empty err.string

      marker_payload = JSON.parse(File.read(marker))
      assert_equal true, marker_payload["ok"]
      assert_equal "success", marker_payload["outcome"]
      assert_equal true, marker_payload["task_complete"]
    end
  end

  def test_terminal_watch_fails_on_task_failed_without_status_polling
    Dir.mktmpdir("harnex-terminal-watch-failed-event") do |repo|
      system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      id = "watch-failed-#{$$}"
      marker = File.join(repo, "failed.json")
      write_terminal_registry(repo, id, port: 9)
      write_terminal_event(
        repo,
        id,
        type: "task_failed",
        seq: 2,
        status: "completed_no_activity",
        outcome_class: "completed_no_activity",
        message: "turn completed without structured activity"
      )

      out = StringIO.new
      err = StringIO.new
      watcher = Harnex::TerminalWatcher.new(id: id, repo_path: repo, fail_marker: marker, out: out, err: err)
      Net::HTTP.stub(:start, ->(*) { flunk("terminal watch should not poll /status after task_failed") }) do
        assert_equal 1, watcher.run
      end

      payload = JSON.parse(out.string)
      assert_equal false, payload["ok"]
      assert_equal false, payload["done"]
      assert_equal "failed", payload["work_state"]
      assert_equal "task_failed", payload["event"]
      assert_equal "turn completed without structured activity", payload["last_error"]
      assert_equal "completed_no_activity", payload["outcome_class"]
      assert_empty err.string

      marker_payload = JSON.parse(File.read(marker))
      assert_equal false, marker_payload["ok"]
      assert_equal "failed", marker_payload["outcome"]
      assert_equal true, marker_payload["task_failed"]
      assert_equal "completed_no_activity", marker_payload["outcome_class"]
    ensure
      FileUtils.rm_f(Harnex.registry_path(repo, id)) if repo && id
    end
  end

  def test_terminal_watch_fails_from_terminal_summary_without_live_registry
    Dir.mktmpdir("harnex-terminal-watch-failed-summary") do |repo|
      system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      id = "watch-summary-failed-#{$$}"
      dispatch_path = File.join(repo, ".harnex", "dispatch.jsonl")
      FileUtils.mkdir_p(File.dirname(dispatch_path))
      File.write(dispatch_path, JSON.generate({
        "meta" => {
          "id" => id,
          "repo" => repo,
          "started_at" => Time.now.iso8601,
          "ended_at" => Time.now.iso8601
        },
        "actual" => {
          "task_complete" => false,
          "exit" => "failure",
          "exit_code" => 7
        },
        "predicted" => {}
      }) + "\n")

      out = StringIO.new
      err = StringIO.new
      watcher = Harnex::TerminalWatcher.new(id: id, repo_path: repo, out: out, err: err)
      assert_equal 7, watcher.run
      assert_empty err.string
      payload = JSON.parse(out.string)
      assert_equal false, payload["ok"]
      assert_equal false, payload["done"]
      assert_equal "failed", payload["work_state"]
      assert_equal true, payload["terminal"]
      assert_equal dispatch_path, payload["summary_out"]
    end
  end

  def test_terminal_watch_timeout_returns_124_without_fail_marker
    Dir.mktmpdir("harnex-terminal-watch-timeout") do |repo|
      system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      id = "watch-timeout-#{$$}"
      marker = File.join(repo, "failed.json")
      write_terminal_event(repo, id, type: "started", seq: 1)

      out = StringIO.new
      err = StringIO.new
      watcher = Harnex::TerminalWatcher.new(id: id, repo_path: repo, max_wait: 0.1, fail_marker: marker, out: out, err: err)
      assert_equal 124, watcher.run
      assert_empty err.string
      payload = JSON.parse(out.string)
      assert_equal "timeout", payload["status"]
      assert_equal false, payload["done"]
      refute File.exist?(marker), "timeout must not be collapsed into fail-marker"
    end
  end

  def test_watch_command_help_returns_zero
    command = Harnex::WatchCommand.new(["--help"])
    out, = capture_io { assert_equal 0, command.run }
    assert_match(/Usage: harnex watch/, out)
    assert_match(/--max-wait DUR/, out)
  end

  private

  def build_watcher(id, stall_after_s:, max_resumes:)
    out = StringIO.new
    err = StringIO.new
    watcher = Harnex::RunWatcher.new(
      id: id,
      repo_root: @repo_root,
      stall_after_s: stall_after_s,
      max_resumes: max_resumes,
      poll_interval_s: 0.0,
      sleeper: ->(_seconds) {},
      out: out,
      err: err
    )
    [watcher, out, err]
  end

  def write_registry(id, port, token: SecureRandom.hex(8))
    path = Harnex.registry_path(@repo_root, id)
    Harnex.write_registry(path, {
      "id" => id,
      "pid" => Process.pid,
      "host" => "127.0.0.1",
      "port" => port,
      "token" => token,
      "repo_root" => @repo_root,
      "started_at" => Time.now.iso8601
    })
    @registry_paths << path
    token
  end

  def write_terminal_registry(repo, id, port:)
    Harnex.write_registry(Harnex.registry_path(repo, id), {
      "id" => id,
      "pid" => Process.pid,
      "host" => "127.0.0.1",
      "port" => port,
      "repo_root" => repo,
      "events_log_path" => Harnex.events_log_path(repo, id),
      "started_at" => Time.now.iso8601
    })
  end

  def write_terminal_event(repo, id, event)
    path = Harnex.events_log_path(repo, id)
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, "ab") { |file| file.write(JSON.generate(event) + "\n") }
  end

  def with_watch_server(statuses:)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    queue = statuses.dup
    mutex = Mutex.new
    sends = []

    server_thread = Thread.new do
      loop do
        client = server.accept
        request_line = client.gets("\r\n")
        break unless request_line

        method, path, = request_line.split(" ", 3)
        headers = {}
        while (line = client.gets("\r\n"))
          line = line.strip
          break if line.empty?

          key, value = line.split(":", 2)
          headers[key.downcase] = value.to_s.strip
        end
        length = headers.fetch("content-length", "0").to_i
        body = length.positive? ? client.read(length) : ""

        case [method, path]
        when ["GET", "/status"]
          payload = mutex.synchronize do
            if queue.length > 1
              queue.shift
            else
              queue.first || { "ok" => true, "agent_state" => "busy", "log_idle_s" => 0 }
            end
          end
          write_json_response(client, 200, payload)
        when ["POST", "/send"]
          payload = body.empty? ? {} : JSON.parse(body)
          mutex.synchronize { sends << payload }
          write_json_response(client, 200, { "ok" => true })
        else
          write_json_response(client, 404, { "ok" => false, "error" => "not found" })
        end
      rescue IOError, Errno::EBADF
        break
      ensure
        client&.close unless client&.closed?
      end
    end

    yield port, sends
  ensure
    server.close if server && !server.closed?
    server_thread&.join(1)
  end

  def write_json_response(client, status, payload)
    reason =
      case status
      when 200 then "OK"
      when 404 then "Not Found"
      else "OK"
      end
    body = JSON.generate(payload)
    client.write("HTTP/1.1 #{status} #{reason}\r\n")
    client.write("Content-Type: application/json\r\n")
    client.write("Content-Length: #{body.bytesize}\r\n")
    client.write("Connection: close\r\n")
    client.write("\r\n")
    client.write(body)
  end
end
