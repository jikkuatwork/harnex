require_relative "../../test_helper"

class StopperTest < Minitest::Test
  def test_help_returns_zero
    stopper = Harnex::Stopper.new(["--help"])
    assert_output(/Usage:/) { assert_equal 0, stopper.run }
  end

  def test_raises_without_id
    stopper = Harnex::Stopper.new([])
    assert_raises(RuntimeError) { stopper.run }
  end

  def test_returns_1_when_no_session
    stopper = Harnex::Stopper.new(["--id", "nonexistent"])
    assert_output(nil, /no session found/) { assert_equal 1, stopper.run }
  end

  def test_stop_parses_json_response
    repo_root = Dir.pwd
    id = "stop-worker-#{$$}"
    token = SecureRandom.hex(16)
    registry_path = Harnex.registry_path(repo_root, id)

    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    server_thread = Thread.new do
      loop do
        client = server.accept
        client.gets("\r\n")
        while (line = client.gets("\r\n"))
          break if line.strip.empty?
        end
        body = JSON.generate(ok: true, signal: "exit_sequence_sent")
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      rescue IOError, Errno::EBADF
        break
      end
    end

    Harnex.write_registry(registry_path, {
      "id" => id,
      "pid" => Process.pid,
      "host" => "127.0.0.1",
      "port" => port,
      "token" => token,
      "repo_root" => repo_root
    })

    stopper = Harnex::Stopper.new(["--id", id])
    out, = capture_io { assert_equal 0, stopper.run }
    data = JSON.parse(out)
    assert_equal true, data["ok"]
    assert_equal "exit_sequence_sent", data["signal"]
  ensure
    server&.close
    server_thread&.join(1)
    FileUtils.rm_f(registry_path) if registry_path
  end

  def test_stop_retries_until_api_server_comes_up
    repo_root = Dir.pwd
    id = "stop-retry-#{$$}"
    token = SecureRandom.hex(16)
    registry_path = Harnex.registry_path(repo_root, id)

    reservation = TCPServer.new("127.0.0.1", 0)
    port = reservation.addr[1]
    reservation.close

    server = nil
    server_thread = Thread.new do
      sleep 0.2
      server = TCPServer.new("127.0.0.1", port)
      client = server.accept
      client.gets("\r\n")
      while (line = client.gets("\r\n"))
        break if line.strip.empty?
      end
      body = JSON.generate(ok: true, signal: "exit_sequence_sent")
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      client.close
    rescue IOError, Errno::EBADF
      nil
    ensure
      server&.close
    end

    Harnex.write_registry(registry_path, {
      "id" => id,
      "pid" => Process.pid,
      "host" => "127.0.0.1",
      "port" => port,
      "token" => token,
      "repo_root" => repo_root
    })

    stopper = Harnex::Stopper.new(["--id", id, "--timeout", "1"])
    out, = capture_io { assert_equal 0, stopper.run }
    data = JSON.parse(out)
    assert_equal true, data["ok"]
    assert_equal "exit_sequence_sent", data["signal"]
  ensure
    server&.close
    server_thread&.join(1)
    FileUtils.rm_f(registry_path) if registry_path
  end

  def test_stop_returns_124_after_retry_timeout
    repo_root = Dir.pwd
    id = "stop-timeout-#{$$}"
    registry_path = Harnex.registry_path(repo_root, id)

    reservation = TCPServer.new("127.0.0.1", 0)
    port = reservation.addr[1]
    reservation.close

    Harnex.write_registry(registry_path, {
      "id" => id,
      "pid" => Process.pid,
      "host" => "127.0.0.1",
      "port" => port,
      "token" => SecureRandom.hex(16),
      "repo_root" => repo_root
    })

    stopper = Harnex::Stopper.new(["--id", id, "--timeout", "0.2"])
    out, = capture_io { assert_equal 124, stopper.run }
    data = JSON.parse(out)
    assert_equal "timeout", data["status"]
  ensure
    FileUtils.rm_f(registry_path) if registry_path
  end
end
