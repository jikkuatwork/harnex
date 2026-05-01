require "io/console"
require "json"
require "pty"

module Harnex
  class Session
    OUTPUT_BUFFER_LIMIT = 64 * 1024

    attr_reader :repo_root, :host, :port, :session_id, :token, :command, :pid, :id, :adapter, :watch, :inbox, :description, :meta, :output_log_path, :events_log_path

    def initialize(adapter:, command:, repo_root:, host:, port: nil, id: DEFAULT_ID, watch: nil, description: nil, meta: nil, inbox_ttl: Inbox::DEFAULT_TTL)
      @adapter = adapter
      @command = command
      @repo_root = repo_root
      @host = host
      @id = Harnex.normalize_id(id)
      @watch = watch
      @description = description.to_s.strip
      @description = nil if @description.empty?
      @meta = meta
      @registry_path = Harnex.registry_path(repo_root, @id)
      @output_log_path = Harnex.output_log_path(repo_root, @id)
      @events_log_path = Harnex.events_log_path(repo_root, @id)
      @session_id = SecureRandom.hex(8)
      @token = SecureRandom.hex(16)
      @port = Harnex.allocate_port(repo_root, @id, port, host: host)
      @mutex = Mutex.new
      @inject_mutex = Mutex.new
      @events_mutex = Mutex.new
      @injected_count = 0
      @last_injected_at = nil
      @started_at = Time.now
      @server = nil
      @reader = nil
      @output_log = nil
      @events_log = nil
      @events_log_seq = 0
      @writer = nil
      @pid = nil
      @term_signal = nil
      @output_buffer = +""
      @output_buffer.force_encoding(Encoding::BINARY)
      @state_machine = SessionState.new(adapter)
      @inbox = Inbox.new(self, @state_machine, ttl: inbox_ttl)
    end

    def self.validate_binary!(command)
      binary = Array(command).first.to_s
      raise BinaryNotFound, "\"\" not found — is it installed and on your PATH?" if binary.empty?

      if binary.include?("/")
        return binary if File.executable?(binary) && !File.directory?(binary)

        raise BinaryNotFound, "\"#{binary}\" not found — is it installed and on your PATH?"
      end

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, binary)
        return path if File.executable?(path) && !File.directory?(path)
      end

      raise BinaryNotFound, "\"#{binary}\" not found — is it installed and on your PATH?"
    end

    def run(validate_binary: true)
      validate_binary! if validate_binary
      prepare_output_log
      prepare_events_log
      @reader, @writer, @pid = PTY.spawn(child_env, *command)
      @writer.sync = true
      emit_started_event

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
      @term_signal = status.signaled? ? status.termsig : nil
      @exit_code = status.exited? ? status.exitstatus : 128 + status.termsig
      emit_exit_event

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
      @output_log&.close unless @output_log&.closed?
      @events_log&.close unless @events_log&.closed?
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
        injected_count: @injected_count,
        output_log_path: output_log_path,
        events_log_path: events_log_path
      }
      payload.merge!(log_activity_snapshot)
      payload[:description] = description if description

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

    def inject_stop
      raise "session is not running" unless pid && Harnex.alive_pid?(pid)

      @inject_mutex.synchronize do
        adapter.inject_exit(@writer)
        @state_machine.force_busy!
      end

      { ok: true, signal: "exit_sequence_sent" }
    end

    def inject_via_adapter(text:, submit:, enter_only:, force: false)
      snapshot = adapter.wait_for_sendable(method(:screen_snapshot), submit: submit, enter_only: enter_only, force: force)
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
        .tap { emit_send_event(text, force: payload[:force]) }
    end

    def sync_window_size
      return unless STDIN.tty?

      @writer.winsize = STDIN.winsize
    rescue StandardError
      nil
    end

    def validate_binary!
      self.class.validate_binary!(command)
    end

    private

    def child_env
      env = {
        "HARNEX_SESSION_ID" => session_id,
        "HARNEX_SESSION_CLI" => adapter.key,
        "HARNEX_ID" => id,
        "HARNEX_SESSION_REPO_ROOT" => repo_root
      }
      env["HARNEX_DESCRIPTION"] = description if description
      env["HARNEX_SPAWNER_PANE"] = ENV["TMUX_PANE"] if ENV["TMUX_PANE"]
      env
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
      payload = registry_payload
      preserved = load_existing_registry_metadata
      payload = payload.merge(preserved) unless preserved.empty?
      Harnex.write_registry(@registry_path, payload)
    end

    def persist_exit_status
      return unless defined?(@exit_code) && !@exit_code.nil?

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
      payload[:signal] = @term_signal if @term_signal
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

    def prepare_output_log
      @output_log&.close unless @output_log&.closed?
      @output_log = File.open(output_log_path, "ab")
      @output_log.sync = true
      @output_log_failed = false
    end

    def prepare_events_log
      @events_log&.close unless @events_log&.closed?
      @events_log = File.open(events_log_path, "ab")
      @events_log.sync = true
      @events_log_failed = false
      @events_log_seq = 0
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
        append_output_log(chunk)
        @output_buffer << chunk
        overflow = @output_buffer.bytesize - OUTPUT_BUFFER_LIMIT
        @output_buffer = @output_buffer.byteslice(overflow, OUTPUT_BUFFER_LIMIT) if overflow.positive?
        @output_buffer.dup
      end
      @state_machine.update(snapshot)
    end

    def append_output_log(chunk)
      return unless @output_log

      @output_log.write(chunk)
    rescue StandardError => e
      return if defined?(@output_log_failed) && @output_log_failed

      @output_log_failed = true
      warn("harnex: failed to write output log #{output_log_path}: #{e.message}")
    end

    def emit_send_event(text, force:)
      compact = text.to_s
      truncated = compact.length > 200
      preview = truncated ? "#{compact[0, 200]}…" : compact
      emit_event("send", msg: preview, msg_truncated: truncated, forced: !!force)
    end

    def emit_started_event
      payload = { pid: @pid }
      payload[:meta] = meta if meta
      emit_event("started", **payload)
    end

    def emit_exit_event
      payload = { code: @exit_code }
      payload[:signal] = @term_signal if @term_signal
      emit_event("exited", **payload)
    end

    def emit_event(type, **payload)
      @events_mutex.synchronize do
        return unless @events_log

        @events_log_seq += 1
        event = {
          schema_version: 1,
          seq: @events_log_seq,
          ts: Time.now.utc.iso8601,
          id: id,
          type: type
        }.merge(payload)
        @events_log.write(JSON.generate(event))
        @events_log.write("\n")
        @events_log.flush
      end
    rescue StandardError => e
      return if defined?(@events_log_failed) && @events_log_failed

      @events_log_failed = true
      warn("harnex: failed to write events log #{events_log_path}: #{e.message}")
    end

    def log_activity_snapshot
      return { log_mtime: nil, log_idle_s: nil } unless File.file?(output_log_path)
      return { log_mtime: nil, log_idle_s: nil } if File.size?(output_log_path).nil?

      mtime = File.mtime(output_log_path)
      idle_seconds = (Time.now - mtime).to_i
      idle_seconds = 0 if idle_seconds.negative?
      {
        log_mtime: mtime.iso8601,
        log_idle_s: idle_seconds
      }
    rescue StandardError
      {
        log_mtime: nil,
        log_idle_s: nil
      }
    end

    def screen_snapshot
      @mutex.synchronize { @output_buffer.dup }
    end

    def load_existing_registry_metadata
      return {} unless File.exist?(@registry_path)

      JSON.parse(File.read(@registry_path)).each_with_object({}) do |(key, value), memo|
        memo[key] = value if key.start_with?("tmux_")
      end
    rescue JSON::ParserError
      {}
    end
  end
end
