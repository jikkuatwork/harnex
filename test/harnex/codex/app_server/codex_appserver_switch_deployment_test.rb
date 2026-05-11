require_relative "../../../test_helper"
require_relative "../../../support/codex_response_fixtures"
require "json"
require "tempfile"

# Plan 30 Phase 2 — Adapter-level switch_deployment.
#
# Deployment A is a scripted IO.pipe server (same pattern as the
# lifecycle test). Deployment B is a real Ruby subprocess that speaks
# JSON-RPC, so the spawn / TERM / KILL paths are exercised end-to-end.
class HarnexCodexAppServerSwitchDeploymentTest < Minitest::Test
  Adapter = Harnex::Adapters::CodexAppServer

  def setup
    @server_in, @client_out = IO.pipe
    @client_in, @server_out = IO.pipe
    @adapter = Adapter.new
    @notifications = []
    @adapter.on_notification { |n| @notifications << n }
    @stub_files = []
  end

  def teardown
    @adapter&.close
    @adapter&.terminate_subprocess
    [@server_in, @client_out, @client_in, @server_out].each do |io|
      io.close unless io.closed?
    rescue StandardError
      nil
    end
    @stub_files.each(&:unlink)
  end

  def wait_for(timeout: 2.0)
    deadline = Time.now + timeout
    until yield
      return false if Time.now > deadline

      sleep 0.01
    end
    true
  end

  def start_deployment_a(thread_id: "thr-a-1", turn_id: "trn-a-1")
    server = Thread.new do
      # initialize
      req = JSON.parse(@server_in.gets)
      @server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: {} }) + "\n")
      @server_out.flush
      @server_in.gets # initialized notification
      # thread/start
      req = JSON.parse(@server_in.gets)
      @server_out.write(JSON.generate({
        jsonrpc: "2.0", id: req["id"],
        result: Fixtures::Codex.thread_start_response(id: thread_id)
      }) + "\n")
      @server_out.flush
      # turn/start
      req = JSON.parse(@server_in.gets)
      @server_out.write(JSON.generate({
        jsonrpc: "2.0", id: req["id"],
        result: Fixtures::Codex.turn_start_response(id: turn_id)
      }) + "\n")
      @server_out.flush
    rescue StandardError
      nil
    end

    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)
    @adapter.dispatch(prompt: "first")

    @server_out.write(JSON.generate({
      jsonrpc: "2.0", method: "turn/completed",
      params: Fixtures::Codex.turn_completed_notification(
        thread_id: thread_id, turn_id: turn_id, status: "completed"
      )
    }) + "\n")
    @server_out.flush

    assert wait_for { @adapter.state == :prompt }, "deployment A must return to :prompt"
    server&.join(1)
  end

  def write_stub_b(thread_id:, log_path:)
    stub = Tempfile.new(["codex-stub-b", ".rb"])
    @stub_files << stub
    stub.write(<<~RUBY)
      require "json"
      STDOUT.sync = true
      thread_id = ARGV[0]
      log = ARGV[1] ? File.open(ARGV[1], "w") : nil
      while (line = STDIN.gets)
        log&.write(line)
        log&.flush
        msg = JSON.parse(line) rescue next
        next unless msg["id"]

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
            result: { "turn" => { "id" => "trn-b-1", "items" => [], "status" => "inProgress" } }
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

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def test_switch_deployment_preserves_thread_id_and_drives_a_new_turn
    start_deployment_a(thread_id: "thr-switch-1")
    assert_equal "thr-switch-1", @adapter.thread_id

    log_path = Tempfile.new(["stub-b-log", ".jsonl"]).path
    stub_b = write_stub_b(thread_id: "thr-switch-1", log_path: log_path)

    @adapter.switch_deployment(deployment_config: {
      command: ["ruby", stub_b.path, "thr-switch-1", log_path]
    })

    # threadId is preserved across the subprocess switch.
    assert_equal "thr-switch-1", @adapter.thread_id
    assert_equal :prompt, @adapter.state

    # Drive a turn through deployment B.
    turn_id = @adapter.dispatch(prompt: "after fallback")
    assert_equal "trn-b-1", turn_id

    @adapter.close

    log = File.readlines(log_path).map { |l| JSON.parse(l) }
    methods = log.map { |m| m["method"] }
    assert_includes methods, "initialize"
    assert_includes methods, "thread/resume"
    assert_includes methods, "turn/start"

    resume = log.find { |m| m["method"] == "thread/resume" }
    assert_equal "thr-switch-1", resume.dig("params", "threadId")
  end

  def test_switch_deployment_subprocess_teardown_bounded_no_orphan_pid
    start_deployment_a(thread_id: "thr-orphan-1")

    log_path = Tempfile.new(["stub-b-orphan-log", ".jsonl"]).path
    stub_b = write_stub_b(thread_id: "thr-orphan-1", log_path: log_path)

    @adapter.switch_deployment(deployment_config: {
      command: ["ruby", stub_b.path, "thr-orphan-1", log_path]
    })

    pid_b = @adapter.pid
    refute_nil pid_b
    assert process_alive?(pid_b), "subprocess B must be alive after switch"

    @adapter.close
    @adapter.terminate_subprocess(term_grace_seconds: 0.5, kill_grace_seconds: 1.0)

    assert wait_for(timeout: 2) { !process_alive?(pid_b) },
           "subprocess B pid=#{pid_b} must be reaped after adapter close + terminate"
  end

  def test_switch_deployment_rejects_when_no_thread_to_resume
    # No start_rpc → no @client.
    err = assert_raises(RuntimeError) do
      @adapter.switch_deployment(deployment_config: { command: ["true"] })
    end
    assert_match(/not started/, err.message)

    # Start, but no thread yet — adapter.thread_id is still nil
    # (no thread/start happened because we don't dispatch).
    server = Thread.new do
      req = JSON.parse(@server_in.gets)
      @server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: {} }) + "\n")
      @server_out.flush
      @server_in.gets # initialized
    rescue StandardError
      nil
    end
    @adapter.start_rpc(read_io: @client_in, write_io: @client_out, pid: nil)
    server.join(1)

    err = assert_raises(RuntimeError) do
      @adapter.switch_deployment(deployment_config: { command: ["true"] })
    end
    assert_match(/no thread to resume/, err.message)
  end
end
