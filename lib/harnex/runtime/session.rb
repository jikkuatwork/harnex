require "io/console"
require "json"
require "pty"

module Harnex
  class Session
    OUTPUT_BUFFER_LIMIT = 64 * 1024

    attr_reader :repo_root, :host, :port, :session_id, :token, :command, :pid, :id, :adapter, :watch, :inbox

    def initialize(adapter:, command:, repo_root:, host:, port: nil, id: DEFAULT_ID, watch: nil)
      @adapter = adapter
      @command = command
      @repo_root = repo_root
      @host = host
      @id = Harnex.normalize_id(id)
      @watch = watch
      @registry_path = Harnex.registry_path(repo_root, @id)
      @session_id = SecureRandom.hex(8)
      @token = SecureRandom.hex(16)
      @port = Harnex.allocate_port(repo_root, @id, port, host: host)
      @mutex = Mutex.new
      @inject_mutex = Mutex.new
      @injected_count = 0
      @last_injected_at = nil
      @started_at = Time.now
      @server = nil
      @reader = nil
      @writer = nil
      @pid = nil
      @output_buffer = +""
      @output_buffer.force_encoding(Encoding::BINARY)
      @state_machine = SessionState.new(adapter)
      @inbox = Inbox.new(self, @state_machine)
    end

    def run
      @reader, @writer, @pid = PTY.spawn(child_env, *command)
      @writer.sync = true

      install_signal_handlers
      sync_window_size
      @server = ApiServer.new(self)
      @server.start
      persist_registry

      stdin_state = STDIN.tty? ? STDIN.raw! : nil
      watch_thread = start_watch_thread
      @inbox.start
      input_thread = start_input_thread
      output_thread = start_output_thread

      _, status = Process.wait2(pid)
      @exit_code = status.exited? ? status.exitstatus : 128 + status.termsig

      output_thread.join(1)
      input_thread&.kill
      watch_thread&.kill
      @exit_code
    ensure
      @inbox.stop
      STDIN.cooked! if STDIN.tty? && stdin_state
      @server&.stop
      persist_exit_status
      cleanup_registry
      @reader&.close unless @reader&.closed?
      @writer&.close unless @writer&.closed?
    end

    def status_payload(include_input_state: true)
      payload = {
        ok: true,
        session_id: session_id,
        repo_root: repo_root,
        repo_key: Harnex.repo_key(repo_root),
        cli: adapter.key,
        id: id,
        pid: pid,
        host: host,
        port: port,
        command: command,
        started_at: @started_at.iso8601,
        last_injected_at: @last_injected_at&.iso8601,
        injected_count: @injected_count
      }

      if watch
        payload[:watch_path] = watch.display_path
        payload[:watch_absolute_path] = watch.absolute_path
        payload[:watch_debounce_seconds] = watch.debounce_seconds
      end

      payload[:input_state] = adapter.input_state(screen_snapshot) if include_input_state
      payload[:agent_state] = @state_machine.to_s
      payload[:inbox] = @inbox.stats
      payload
    end

    def auth_ok?(header)
      header == "Bearer #{token}"
    end

    def inject(text, newline: true)
      raise "session is not running" unless pid && Harnex.alive_pid?(pid)

      inject_sequence([{ text: text, newline: newline }])
    end

    def inject_exit
      raise "session is not running" unless pid && Harnex.alive_pid?(pid)

      sequence = adapter.exit_sequence
      inject_sequence([{ text: sequence, newline: false }])
    end

    def inject_via_adapter(text:, submit:, enter_only:, force: false)
      snapshot = wait_for_sendable_snapshot(submit: submit, enter_only: enter_only, force: force)
      payload = adapter.build_send_payload(
        text: text,
        submit: submit,
        enter_only: enter_only,
        screen_text: snapshot,
        force: force
      )

      result =
        if payload[:steps]
          inject_sequence(payload.fetch(:steps))
        else
          inject(payload.fetch(:text), newline: payload.fetch(:newline, false))
        end

      result.merge(
        cli: adapter.key,
        input_state: payload[:input_state],
        force: payload[:force]
      )
    end

    def sync_window_size
      return unless STDIN.tty?

      @writer.winsize = STDIN.winsize
    rescue StandardError
      nil
    end

    private

    def child_env
      {
        "HARNEX_SESSION_ID" => session_id,
        "HARNEX_SESSION_CLI" => adapter.key,
        "HARNEX_ID" => id,
        "HARNEX_SESSION_REPO_ROOT" => repo_root
      }
    end

    def wait_for_sendable_snapshot(submit:, enter_only:, force:)
      snapshot = screen_snapshot
      return snapshot if force

      wait_seconds = adapter.send_wait_seconds(submit: submit, enter_only: enter_only).to_f
      return snapshot unless wait_seconds.positive?

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_seconds
      state = adapter.input_state(snapshot)

      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline &&
            adapter.wait_for_sendable_state?(state, submit: submit, enter_only: enter_only)
        sleep 0.05
        snapshot = screen_snapshot
        state = adapter.input_state(snapshot)
      end

      snapshot
    end

    def inject_sequence(steps)
      @inject_mutex.synchronize do
        total_bytes = 0
        newline = false

        steps.each do |step|
          delay_ms = step[:delay_ms].to_i
          sleep(delay_ms / 1000.0) if delay_ms.positive?

          payload = step.fetch(:text, "").dup
          newline = step.fetch(:newline, false)
          payload << "\n" if newline
          total_bytes += write_payload(payload)
        end

        result = finish_injection(bytes_written: total_bytes, newline: newline)
        @state_machine.force_busy!
        result
      end
    end

    def write_payload(payload)
      @mutex.synchronize do
        bytes = @writer.write(payload)
        @writer.flush
        bytes
      end
    end

    def finish_injection(bytes_written:, newline:)
      injected_count = @mutex.synchronize do
        @injected_count += 1
        @last_injected_at = Time.now
        persist_registry
        @injected_count
      end

      {
        ok: true,
        bytes_written: bytes_written,
        injected_count: injected_count,
        newline: newline
      }
    end

    def registry_payload
      status_payload(include_input_state: false).merge(
        token: token,
        cwd: Dir.pwd
      )
    end

    def persist_registry
      Harnex.write_registry(@registry_path, registry_payload)
    end

    def persist_exit_status
      exit_path = Harnex.exit_status_path(repo_root, id)
      payload = {
        ok: true,
        id: id,
        cli: adapter.key,
        session_id: session_id,
        repo_root: repo_root,
        exit_code: @exit_code,
        started_at: @started_at.iso8601,
        exited_at: Time.now.iso8601,
        injected_count: @injected_count
      }
      Harnex.write_registry(exit_path, payload)
    rescue StandardError
      nil
    end

    def cleanup_registry
      current = File.exist?(@registry_path) ? JSON.parse(File.read(@registry_path)) : nil
      return unless current && current["session_id"] == session_id

      FileUtils.rm_f(@registry_path)
    rescue JSON::ParserError
      nil
    end

    def start_input_thread
      Thread.new do
        loop do
          chunk = STDIN.readpartial(4096)
          @inject_mutex.synchronize do
            @mutex.synchronize do
              @writer.write(chunk)
              @writer.flush
            end
          end
        rescue EOFError, Errno::EIO, IOError
          break
        end
      end
    end

    def start_output_thread
      Thread.new do
        loop do
          chunk = @reader.readpartial(4096)
          record_output(chunk)
          STDOUT.write(chunk)
          STDOUT.flush
        rescue EOFError, Errno::EIO, IOError
          break
        end
      end
    end

    def start_watch_thread
      return nil unless watch

      FileChangeHook.new(self, watch).start
    end

    def install_signal_handlers
      %w[INT TERM HUP QUIT].each do |signal_name|
        Signal.trap(signal_name) { forward_signal(signal_name) }
      end
      Signal.trap("WINCH") { sync_window_size }
    end

    def forward_signal(signal_name)
      return unless pid

      Process.kill(signal_name, pid)
    rescue Errno::ESRCH
      nil
    end

    def record_output(chunk)
      snapshot = @mutex.synchronize do
        @output_buffer << chunk
        overflow = @output_buffer.bytesize - OUTPUT_BUFFER_LIMIT
        @output_buffer = @output_buffer.byteslice(overflow, OUTPUT_BUFFER_LIMIT) if overflow.positive?
        @output_buffer.dup
      end
      @state_machine.update(snapshot)
    end

    def screen_snapshot
      @mutex.synchronize { @output_buffer.dup }
    end
  end
end
