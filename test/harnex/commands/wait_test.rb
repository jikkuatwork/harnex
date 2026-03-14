require_relative "../../test_helper"

class WaiterTest < Minitest::Test
  # --- help ---

  def test_help_returns_zero
    waiter = Harnex::Waiter.new(["--help"])
    assert_output(/Usage:/) { assert_equal 0, waiter.run }
  end

  def test_help_mentions_until
    waiter = Harnex::Waiter.new(["--help"])
    assert_output(/--until STATE/) { waiter.run }
  end

  # --- requires --id ---

  def test_raises_without_id
    waiter = Harnex::Waiter.new([])
    assert_raises(RuntimeError) { waiter.run }
  end

  # --- no session found (wait-until-exit) ---

  def test_returns_1_when_no_session
    waiter = Harnex::Waiter.new(["--id", "nonexistent"])
    assert_output(nil, /no session found/) { assert_equal 1, waiter.run }
  end

  # --- no session found (wait-until-state) ---

  def test_until_prompt_returns_1_when_no_session
    waiter = Harnex::Waiter.new(["--id", "nonexistent", "--until", "prompt"])
    assert_output(nil, /no session found/) { assert_equal 1, waiter.run }
  end

  # --- wait-until-exit reads exit status file ---

  def test_reads_exit_status_file_when_session_gone
    repo_root = Dir.pwd
    id = "exited-worker-#{$$}"
    exit_path = Harnex.exit_status_path(repo_root, id)

    File.write(exit_path, JSON.generate(ok: true, id: id, exit_code: 0, status: "exited"))

    waiter = Harnex::Waiter.new(["--id", id])
    out, = capture_io { assert_equal 0, waiter.run }
    data = JSON.parse(out)
    assert_equal id, data["id"]
  ensure
    FileUtils.rm_f(exit_path) if exit_path
  end

  # --- wait-until-state with immediate prompt ---

  def test_until_prompt_succeeds_when_api_returns_prompt
    repo_root = Dir.pwd
    id = "prompt-worker-#{$$}"
    token = SecureRandom.hex(16)

    # Start a fake HTTP server that always returns agent_state: "prompt"
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    server_thread = Thread.new do
      loop do
        client = server.accept
        client.gets("\r\n") # request line
        while (line = client.gets("\r\n"))
          break if line.strip.empty?
        end
        body = JSON.generate(agent_state: "prompt", ok: true)
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      rescue IOError, Errno::EBADF
        break
      end
    end

    # Write a registry entry pointing at our fake server
    registry_path = Harnex.registry_path(repo_root, id)
    Harnex.write_registry(registry_path, {
      "id" => id,
      "pid" => Process.pid, # our own pid, guaranteed alive
      "host" => "127.0.0.1",
      "port" => port,
      "token" => token,
      "repo_root" => repo_root
    })

    waiter = Harnex::Waiter.new(["--id", id, "--until", "prompt"])
    out, err = capture_io { assert_equal 0, waiter.run }
    data = JSON.parse(out)
    assert data["ok"]
    assert_equal "prompt", data["state"]
    assert_equal id, data["id"]
    assert data.key?("waited_seconds")
    assert_match(/waiting for.*prompt/, err)
  ensure
    server&.close
    server_thread&.join(1)
    FileUtils.rm_f(registry_path) if registry_path
  end

  # --- wait-until-state timeout ---

  def test_until_prompt_times_out
    repo_root = Dir.pwd
    id = "timeout-worker-#{$$}"
    token = SecureRandom.hex(16)

    # Fake server that always returns agent_state: "busy"
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    server_thread = Thread.new do
      loop do
        client = server.accept
        client.gets("\r\n")
        while (line = client.gets("\r\n"))
          break if line.strip.empty?
        end
        body = JSON.generate(agent_state: "busy", ok: true)
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      rescue IOError, Errno::EBADF
        break
      end
    end

    registry_path = Harnex.registry_path(repo_root, id)
    Harnex.write_registry(registry_path, {
      "id" => id,
      "pid" => Process.pid,
      "host" => "127.0.0.1",
      "port" => port,
      "token" => token,
      "repo_root" => repo_root
    })

    waiter = Harnex::Waiter.new(["--id", id, "--until", "prompt", "--timeout", "0.1"])
    out, = capture_io { assert_equal 124, waiter.run }
    data = JSON.parse(out)
    refute data["ok"]
    assert_equal "timeout", data["status"]
    assert_equal "busy", data["state"]
  ensure
    server&.close
    server_thread&.join(1)
    FileUtils.rm_f(registry_path) if registry_path
  end

  # --- wait-until-state detects process exit ---

  def test_until_prompt_returns_1_when_process_exits
    repo_root = Dir.pwd
    id = "dead-worker-#{$$}"

    # Spawn and wait so we have a dead PID
    dead_pid = spawn("true")
    Process.wait(dead_pid)

    registry_path = Harnex.registry_path(repo_root, id)
    Harnex.write_registry(registry_path, {
      "id" => id,
      "pid" => dead_pid,
      "host" => "127.0.0.1",
      "port" => 19999,
      "repo_root" => repo_root
    })

    waiter = Harnex::Waiter.new(["--id", id, "--until", "prompt"])
    out, err = capture_io { assert_equal 1, waiter.run }

    # The dead PID means read_registry returns nil (active_sessions cleans it),
    # so we get "no session found" on stderr
    if out.empty?
      assert_match(/no session found/, err)
    else
      data = JSON.parse(out)
      refute data["ok"]
      assert_equal "exited", data["state"]
    end
  ensure
    FileUtils.rm_f(registry_path) if registry_path
  end
end
