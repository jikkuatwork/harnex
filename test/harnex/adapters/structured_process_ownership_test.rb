require_relative "../../test_helper"
require "rbconfig"
require "timeout"

# Only local Ruby children. Every PID read below was created by this fixture;
# cleanup always uses positive PIDs, including on the pre-fix (shared-group) code.
class StructuredProcessOwnershipTest < Minitest::Test
  CHILD = <<~'RUBY'
    require "json"
    require "rbconfig"
    STDOUT.sync = true
    dir, mode = ARGV
    File.write(File.join(dir, "root"), Process.pid.to_s)
    if mode == "tree" || mode == "orphan"
      descendant = Process.spawn(RbConfig.ruby, "-e", <<~'DESC', dir, in: File::NULL, out: File::NULL, err: File::NULL)
        trap("TERM", "IGNORE")
        File.write(File.join(ARGV[0], "descendant"), Process.pid.to_s)
        sleep 60
      DESC
    end
    STDIN.each_line do |line|
      message = JSON.parse(line)
      File.write(File.join(dir, "request"), line)
      next if mode == "stall"
      if message["method"] == "initialize"
        puts JSON.generate(jsonrpc: "2.0", id: message["id"], result: {})
      end
      ready = message["method"] == "initialized" || message["type"] == "get_state"
      if ready && ["orphan", "exit"].include?(mode)
        sleep 0.01 until mode == "exit" || File.exist?(File.join(dir, "descendant"))
        exit! 23
      end
    end
  RUBY

  def setup
    @dir = Dir.mktmpdir("harnex-owned-process-")
  end

  def teardown
    # Do not rely on the implementation under test to clean failed regressions.
    %w[descendant root fallback/descendant fallback/root].each do |name|
      path = File.join(@dir, name)
      Process.kill("KILL", Integer(File.read(path))) if File.exist?(path)
    rescue Errno::ESRCH
      nil
    end
    @adapter&.close rescue nil
    @starter&.join(3)
    FileUtils.rm_rf(@dir)
  end

  { pi: Harnex::Adapters::Pi, codex: Harnex::Adapters::CodexAppServer }.each do |name, klass|
    define_method("test_#{name}_spawn_callback_precedes_protocol_io") do
      build_adapter(klass, "stall")
      callbacks = Queue.new
      @adapter.on_spawn do |pid|
        callbacks << [pid, @adapter.pid, Process.getpgid(pid), File.exist?(File.join(@dir, "request"))]
      end
      start_async
      pid, adapter_pid, pgid, request_written = Timeout.timeout(3) { callbacks.pop }
      assert_equal adapter_pid, pid
      assert_equal pid, pgid
      refute_equal Process.getpgrp, pgid
      refute request_written, "owner must learn the PID before handshake/state writes"
      wait_file("request")
      assert @starter.alive?, "Codex must still be waiting for initialize" if name == :codex
      assert @adapter.terminate_subprocess(term_grace_seconds: 0.1, kill_grace_seconds: 1)
      assert @starter.join(3), "termination must release the blocked handshake"
      assert_instance_of StandardError, @startup_error if name == :codex
      assert callbacks.empty?, "one callback per spawn"
    end

    define_method("test_#{name}_spawn_isolates_worker_group") do
      build_adapter(klass, "tree")
      @adapter.start_rpc
      descendant = Integer(wait_file("descendant"))
      assert_equal @adapter.pid, Process.getpgid(@adapter.pid)
      assert_equal @adapter.pid, Process.getpgid(descendant)
      refute_equal Process.getpgrp, Process.getpgid(descendant)
    end

    define_method("test_#{name}_termination_escalates_for_descendant_after_root_term_exit") do
      build_adapter(klass, "tree")
      @adapter.start_rpc
      descendant = Integer(wait_file("descendant"))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @adapter.terminate_subprocess(term_grace_seconds: 0.1, kill_grace_seconds: 1)
      assert wait_until { !alive?(descendant) }, "TERM-ignoring descendant survived root exit"
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
    end

    define_method("test_#{name}_reaping_root_keeps_group_cleanup_and_exit_status") do
      build_adapter(klass, "orphan")
      @adapter.start_rpc
      descendant = Integer(wait_file("descendant"))
      status = Timeout.timeout(3) { @adapter.wait_for_exit }
      assert_equal 23, status.exitstatus
      assert alive?(descendant), "fixture descendant must survive natural root exit"
      @adapter.terminate_subprocess(term_grace_seconds: 0.1, kill_grace_seconds: 1)
      assert wait_until { !alive?(descendant) }, "reaping the root must not discard group ownership"
      calls = []
      Process.stub(:kill, ->(signal, target) { calls << [signal, target]; raise Errno::ESRCH }) do
        @adapter.terminate_subprocess(term_grace_seconds: 0.01, kill_grace_seconds: 0.01)
        calls.clear
        @adapter.terminate_subprocess(term_grace_seconds: 0.01, kill_grace_seconds: 0.01)
        assert_empty calls, "a gone group must not be signalled again"
      end
    end

    define_method("test_#{name}_injected_io_without_pid_still_notifies_owner") do
      build_adapter(klass, "unused")
      server_in, client_out = IO.pipe
      client_in, server_out = IO.pipe
      observed = []
      @adapter.on_spawn { |pid| observed << pid }
      server = Thread.new do
        if name == :codex
          msg = JSON.parse(server_in.gets)
          server_out.puts JSON.generate(jsonrpc: "2.0", id: msg["id"], result: {})
        end
      end
      @adapter.start_rpc(read_io: client_in, write_io: client_out)
      assert_equal [nil], observed
      refute @adapter.terminate_subprocess(term_grace_seconds: 0, kill_grace_seconds: 0)
    ensure
      server_out&.close unless server_out&.closed?
      @adapter&.close rescue nil
      server&.join(1)
      [server_in, client_out, client_in, server_out].compact.each { |io| io.close unless io.closed? }
    end

    define_method("test_#{name}_injected_pid_never_claims_group_ownership") do
      build_adapter(klass, "unused")
      server_in, client_out = IO.pipe
      client_in, server_out = IO.pipe
      @adapter.on_spawn { |pid| assert_equal 4242, pid }
      server = Thread.new do
        if name == :codex
          msg = JSON.parse(server_in.gets)
          server_out.puts JSON.generate(jsonrpc: "2.0", id: msg["id"], result: {})
        end
      end
      @adapter.start_rpc(read_io: client_in, write_io: client_out, pid: 4242)
      calls = []
      Process.stub(:kill, ->(signal, target) { calls << [signal, target]; raise Errno::ESRCH }) do
        @adapter.terminate_subprocess(term_grace_seconds: 0.01, kill_grace_seconds: 0.01)
        server_out.close
        @adapter.close
        @adapter = nil
      end
      assert calls.all? { |_signal, target| target == 4242 }, "injected PID is not authority over its process group"
    ensure
      server&.join(1)
      [server_in, client_out, client_in, server_out].compact.each { |io| io.close unless io.closed? }
      Process.stub(:kill, ->(*_args) { raise Errno::ESRCH }) { @adapter&.close rescue nil }
      @adapter = nil
    end
  end

  def test_codex_fallback_publishes_new_owned_child_before_blocked_handshake
    build_adapter(Harnex::Adapters::CodexAppServer, "idle")
    @adapter.start_rpc
    prior_pid = @adapter.pid
    @adapter.instance_variable_set(:@thread_id, "fixture-thread")
    dir = File.join(@dir, "fallback")
    Dir.mkdir(dir)
    callbacks = Queue.new
    @adapter.on_spawn do |pid|
      callbacks << [pid, @adapter.pid, Process.getpgid(pid), File.exist?(File.join(dir, "request"))]
    end
    @starter = Thread.new do
      @adapter.switch_deployment(deployment_config: { command: [RbConfig.ruby, "-e", CHILD, dir, "stall"] })
    rescue StandardError => error
      @startup_error = error
    end
    pid, adapter_pid, pgid, request_written = Timeout.timeout(3) { callbacks.pop }
    refute_equal prior_pid, pid
    assert_equal pid, adapter_pid
    assert_equal pid, pgid
    refute_equal Process.getpgrp, pgid
    refute request_written
    wait_file("fallback/request")
    assert @adapter.terminate_subprocess(term_grace_seconds: 0.1, kill_grace_seconds: 1)
    assert @starter.join(3), "fallback initialize must be released by owned-group termination"
    assert_instance_of StandardError, @startup_error
    refute alive?(prior_pid)
    refute alive?(pid)
  end

  private

  def build_adapter(klass, mode)
    @adapter = klass.new
    command = [RbConfig.ruby, "-e", CHILD, @dir, mode]
    @adapter.define_singleton_method(:build_command) { command }
    @adapter.define_singleton_method(:validate_runtime!) { true }
  end

  def start_async
    @starter = Thread.new do
      @adapter.start_rpc
    rescue StandardError => error
      @startup_error = error
    end
  end

  def wait_file(name)
    path = File.join(@dir, name)
    raise "fixture #{name} did not appear" unless wait_until { File.exist?(path) && !File.empty?(path) }

    File.read(path)
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
    true
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
