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
