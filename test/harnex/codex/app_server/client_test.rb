require_relative "../../../test_helper"
require "json"
require "tempfile"

# Plan 30 Phase 2 — Client-level fallback primitives. Adapter-level
# wiring is exercised in codex_appserver_switch_deployment_test.rb.
class HarnexCodexAppServerClientTest < Minitest::Test
  Client = Harnex::Codex::AppServer::Client

  def setup
    @ios = []
  end

  def teardown
    @ios.each do |io|
      io.close unless io.closed?
    rescue StandardError
      nil
    end
  end

  def make_pipes
    server_in, client_out = IO.pipe
    client_in, server_out = IO.pipe
    @ios.concat([server_in, client_out, client_in, server_out])
    [server_in, client_out, client_in, server_out]
  end

  def wait_for(timeout: 1.0)
    deadline = Time.now + timeout
    until yield
      return false if Time.now > deadline

      sleep 0.01
    end
    true
  end

  # ---- stop_for_fallback ----

  def test_stop_for_fallback_drains_pending_requests
    server_in, client_out, client_in, _server_out = make_pipes
    client = Client.new(read_io: client_in, write_io: client_out)
    client.start

    raised = nil
    request_thread = Thread.new do
      client.request("turn/start", { foo: "bar" })
    rescue StandardError => e
      raised = e
    end

    # Give the request a tick to land in @pending.
    assert wait_for { server_in.gets } # consume the queued request line

    client.stop_for_fallback(term_grace_seconds: 0.1, kill_grace_seconds: 0.1)
    request_thread.join(1)

    refute_nil raised, "pending request must be drained with an exception"
    assert_match(/closed for fallback/, raised.message)
  end

  def test_stop_for_fallback_issues_turn_interrupt_when_in_flight
    server_in, client_out, client_in, _server_out = make_pipes
    client = Client.new(read_io: client_in, write_io: client_out)
    client.start

    seen = []
    reader = Thread.new do
      while (line = server_in.gets)
        seen << JSON.parse(line)
        # Never reply — exercise the bounded interrupt grace.
      end
    rescue StandardError
      nil
    end

    client.stop_for_fallback(
      in_flight_turn: { threadId: "thr-1", turnId: "trn-1" },
      term_grace_seconds: 0.1,
      kill_grace_seconds: 0.1,
      interrupt_grace_seconds: 0.2
    )

    reader.join(1)
    interrupt = seen.find { |m| m["method"] == "turn/interrupt" }
    refute_nil interrupt, "stop_for_fallback must wire turn/interrupt onto the wire before teardown"
    assert_equal "thr-1", interrupt.dig("params", "threadId")
    assert_equal "trn-1", interrupt.dig("params", "turnId")
  end

  def test_stop_for_fallback_terminates_subprocess_with_bounded_grace
    # Spawn a real subprocess that ignores stdin and sleeps. Verify the
    # PID is gone after stop_for_fallback's TERM/KILL escalation.
    client = Client.spawn(deployment_config: { command: ["sleep", "30"] })
    @ios << client.instance_variable_get(:@read_io)
    @ios << client.instance_variable_get(:@write_io)

    pid = client.pid
    refute_nil pid
    assert process_alive?(pid), "sleep subprocess must be alive before stop"

    ok = client.stop_for_fallback(term_grace_seconds: 0.5, kill_grace_seconds: 1.0)
    assert ok, "stop_for_fallback must return true after successful teardown"

    assert wait_for(timeout: 2) { !process_alive?(pid) },
           "subprocess pid=#{pid} must be reaped after stop_for_fallback"
  end

  def test_stop_for_fallback_is_idempotent
    server_in, client_out, client_in, _server_out = make_pipes
    @ios = [server_in, client_out, client_in] # _server_out kept to drive nothing
    client = Client.new(read_io: client_in, write_io: client_out)
    client.start

    assert client.stop_for_fallback(term_grace_seconds: 0.05, kill_grace_seconds: 0.05)
    # Second call must not raise and must remain truthy (already closed).
    assert client.stop_for_fallback(term_grace_seconds: 0.05, kill_grace_seconds: 0.05)
  end

  # ---- spawn / spawn_with_fallback ----

  def test_spawn_requires_command
    assert_raises(ArgumentError) do
      Client.spawn(deployment_config: {})
    end
    assert_raises(ArgumentError) do
      Client.spawn(deployment_config: { command: [] })
    end
  end

  def test_spawn_with_fallback_requires_prior_thread_id
    assert_raises(ArgumentError) do
      Client.spawn_with_fallback(
        prior_thread_id: nil,
        deployment_config: { command: ["true"] },
        handshake_params: {}
      )
    end
    assert_raises(ArgumentError) do
      Client.spawn_with_fallback(
        prior_thread_id: "",
        deployment_config: { command: ["true"] },
        handshake_params: {}
      )
    end
  end

  def test_spawn_with_fallback_runs_initialize_handshake_and_resume
    stub = write_stub_server
    log_path = Tempfile.new(["codex-stub-log", ".jsonl"]).path

    client = Client.spawn_with_fallback(
      prior_thread_id: "thr-resume-1",
      deployment_config: { command: ["ruby", stub.path, "thr-resume-1", log_path] },
      handshake_params: { clientInfo: { name: "harnex-test" } }
    )

    assert_kind_of Client, client
    assert_predicate client.pid, :positive?

    # Drive a turn through to confirm the stub is alive and the client is
    # ready for normal traffic post-resume.
    result = client.request("turn/start", { threadId: "thr-resume-1" })
    assert_equal "trn-stub", result.dig("turn", "id")

    client.stop_for_fallback(term_grace_seconds: 0.5, kill_grace_seconds: 1.0)

    log_lines = File.readlines(log_path).map { |l| JSON.parse(l) }
    methods = log_lines.map { |m| m["method"] }
    assert_equal %w[initialize initialized thread/resume turn/start], methods,
                 "handshake must be: initialize -> initialized -> thread/resume, then turn"

    resume = log_lines.find { |m| m["method"] == "thread/resume" }
    assert_equal "thr-resume-1", resume.dig("params", "threadId")
  ensure
    stub&.unlink
  end

  private

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  # Minimal JSON-RPC stub: replies to initialize / thread/resume /
  # turn/start, logs every inbound line to log_path for assertion.
  def write_stub_server
    stub = Tempfile.new(["codex-stub", ".rb"])
    stub.write(<<~RUBY)
      require "json"
      STDOUT.sync = true
      thread_id = ARGV[0]
      log = ARGV[1] ? File.open(ARGV[1], "w") : nil
      while (line = STDIN.gets)
        log&.write(line)
        log&.flush
        msg = JSON.parse(line) rescue next
        next unless msg["id"] # notifications: log only

        case msg["method"]
        when "initialize"
          STDOUT.puts JSON.generate({ jsonrpc: "2.0", id: msg["id"], result: {} })
        when "thread/resume"
          STDOUT.puts JSON.generate({
            jsonrpc: "2.0", id: msg["id"],
            result: { "thread" => { "id" => thread_id } }
          })
        when "turn/start"
          STDOUT.puts JSON.generate({
            jsonrpc: "2.0", id: msg["id"],
            result: { "turn" => { "id" => "trn-stub", "items" => [], "status" => "inProgress" } }
          })
        else
          STDOUT.puts JSON.generate({
            jsonrpc: "2.0", id: msg["id"],
            error: { code: -32601, message: "unknown" }
          })
        end
      end
    RUBY
    stub.close
    stub
  end
end
