require "io/console"
require "json"
require "pty"

module Harnex
  class Session
    OUTPUT_BUFFER_LIMIT = 64 * 1024
    TRANSCRIPT_TAIL_BYTES = 16 * 1024
    USAGE_FIELDS = %i[
      input_tokens output_tokens reasoning_tokens cached_tokens total_tokens agent_session_id
    ].freeze
    class EventCounters
      def initialize
        @counts = {
          stalls: 0,
          force_resumes: 0,
          disconnections: 0,
          compactions: 0
        }
      end

      def record(type)
        case type.to_s
        when "log_idle"
          @counts[:stalls] += 1
        when "resume"
          @counts[:force_resumes] += 1
        when "disconnect", "disconnection", "disconnected"
          @counts[:disconnections] += 1
        when "compaction"
          @counts[:compactions] += 1
        end
      end

      def snapshot
        @counts.dup
      end
    end

    attr_reader :repo_root, :host, :port, :session_id, :token, :command, :pid, :id, :adapter, :watch, :inbox, :description, :meta, :summary_out, :output_log_path, :events_log_path

    def initialize(adapter:, command:, repo_root:, host:, port: nil, id: DEFAULT_ID, watch: nil, description: nil, meta: nil, summary_out: nil, inbox_ttl: Inbox::DEFAULT_TTL, auto_stop: false)
      @adapter = adapter
      @command = command
      @repo_root = repo_root
      @host = host
      @id = Harnex.normalize_id(id)
      @watch = watch
      @description = description.to_s.strip
      @description = nil if @description.empty?
      @meta = meta
      @summary_out = summary_out.to_s.strip
      @summary_out = nil if @summary_out.empty?
      @registry_path = Harnex.registry_path(repo_root, @id)
      @output_log_path = Harnex.output_log_path(repo_root, @id)
      @events_log_path = Harnex.events_log_path(repo_root, @id)
      @session_id = SecureRandom.hex(8)
      @token = SecureRandom.hex(16)
      @port = Harnex.allocate_port(repo_root, @id, port, host: host)
      @mutex = Mutex.new
      @inject_mutex = Mutex.new
      @events_mutex = Mutex.new
      @stop_mutex = Mutex.new
      @auto_stop_mutex = Mutex.new
      @injected_count = 0
      @last_injected_at = nil
      @started_at = Time.now
      @server = nil
      @reader = nil
      @output_log = nil
      @events_log = nil
      @events_log_seq = 0
      @event_counters = EventCounters.new
      @git_start = {}
      @git_end = {}
      @usage_summary = {}
      @ended_at = nil
      @exit_reason = nil
      @turn_started_seen = false
      @last_completed_at = nil
      @auto_stop = !!auto_stop
      @auto_stop_fired = false
      @auto_stop_seen_busy = false
      @stop_requested = false
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

      return run_jsonrpc if adapter.transport == :stdio_jsonrpc

      run_pty
    end

    def run_pty
      @reader, @writer, @pid = PTY.spawn(child_env, *command)
      @writer.sync = true
      arm_auto_stop_after_initial_context
      emit_started_event
      emit_git_start_event

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
      @ended_at = Time.now

      output_thread.join(1)
      emit_session_end_telemetry
      @exit_reason = classify_exit
      summary_record = build_summary_record
      append_summary_record(summary_record)
      emit_summary_event
      emit_exit_event
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
      payload[:last_completed_at] = @last_completed_at&.iso8601
      payload[:model] = meta_hash["model"]
      payload[:effort] = meta_hash["effort"]
      payload[:auto_disconnects] = @event_counters.snapshot[:disconnections]
      payload
    end

    def auth_ok?(header)
      header == "Bearer #{token}"
    end

    def inject(text, newline: true)
      raise "session is not running" unless pid && Harnex.alive_pid?(pid)

      inject_sequence([{ text: text, newline: newline }])
    end

    def inject_stop(turn_id: nil)
      unless adapter.transport == :stdio_jsonrpc
        raise "session is not running" unless pid && Harnex.alive_pid?(pid)
      end

      return { ok: true, signal: "already_requested" } if stop_requested!

      if adapter.transport == :stdio_jsonrpc
        @inject_mutex.synchronize do
          begin
            adapter.interrupt(turn_id: turn_id)
          rescue StandardError
            nil
          end
          @state_machine.force_busy!
        end
        if adapter.respond_to?(:terminate_subprocess)
          Thread.new do
            begin
              adapter.terminate_subprocess
            rescue Errno::ESRCH, StandardError
              nil
            end
          end
        end
        return { ok: true, signal: "interrupt_sent" }
      end

      @inject_mutex.synchronize do
        adapter.inject_exit(@writer)
        @state_machine.force_busy!
      end

      { ok: true, signal: "exit_sequence_sent" }
    end

    def inject_via_adapter(text:, submit:, enter_only:, force: false)
      if adapter.transport == :stdio_jsonrpc
        return inject_via_jsonrpc(text: text, submit: submit, enter_only: enter_only, force: force)
      end

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

    def inject_via_jsonrpc(text:, submit:, enter_only:, force: false)
      payload = adapter.build_send_payload(
        text: text,
        submit: submit,
        enter_only: enter_only,
        screen_text: nil,
        force: force
      )
      dispatch = payload.fetch(:dispatch).dup
      dispatch[:model] = meta_hash["model"] if meta_hash["model"] && !dispatch.key?(:model)
      dispatch[:effort] = meta_hash["effort"] if meta_hash["effort"] && !dispatch.key?(:effort)

      turn_id = nil
      @inject_mutex.synchronize do
        turn_id = adapter.dispatch(**dispatch)
        @state_machine.force_busy!
        @injected_count += 1
        @last_injected_at = Time.now
        persist_registry
      end

      emit_send_event(dispatch.fetch(:prompt, text), force: payload[:force])
      {
        ok: true,
        cli: adapter.key,
        bytes_written: dispatch.fetch(:prompt, text).to_s.bytesize,
        injected_count: @injected_count,
        newline: false,
        input_state: payload[:input_state],
        force: payload[:force],
        turn_id: turn_id
      }
    end

    def sync_window_size
      return unless STDIN.tty?
      return unless @writer

      @writer.winsize = STDIN.winsize
    rescue StandardError
      nil
    end

    def validate_binary!
      self.class.validate_binary!(command)
    end

    private

    def run_jsonrpc
      adapter.on_notification { |msg| handle_rpc_notification(msg) }
      adapter.on_disconnect { |err| handle_rpc_disconnect(err) }

      adapter.start_rpc(env: child_env, cwd: repo_root)
      @pid = adapter.pid
      @state_machine.force_prompt!
      emit_started_event
      emit_git_start_event

      install_signal_handlers
      @server = ApiServer.new(self)
      @server.start
      persist_registry

      watch_thread = start_watch_thread
      @inbox.start
      dispatch_initial_prompt

      if @pid
        begin
          _, status = Process.wait2(@pid)
          @term_signal = status.signaled? ? status.termsig : nil
          @exit_code = status.exited? ? status.exitstatus : 128 + status.termsig
        rescue Errno::ECHILD
          @exit_code = 0
        end
      else
        @rpc_done_lock = Mutex.new
        @rpc_done_cond = ConditionVariable.new
        @rpc_done_lock.synchronize { @rpc_done_cond.wait(@rpc_done_lock) until @rpc_done }
        @exit_code = 0
      end
      @ended_at = Time.now

      emit_session_end_telemetry
      @exit_reason = classify_exit
      summary_record = build_summary_record
      append_summary_record(summary_record)
      emit_summary_event
      emit_exit_event
      watch_thread&.kill
      @exit_code
    ensure
      @inbox.stop
      @server&.stop
      begin
        adapter.close
      rescue StandardError
        nil
      end
      persist_exit_status
      cleanup_registry
      @output_log&.close unless @output_log&.closed?
      @events_log&.close unless @events_log&.closed?
    end

    def signal_rpc_done!
      @rpc_done = true
      if defined?(@rpc_done_lock) && @rpc_done_lock
        @rpc_done_lock.synchronize { @rpc_done_cond&.signal }
      end
    end

    def handle_rpc_notification(message)
      method = message["method"]
      params = message["params"] || {}

      case method
      when "thread/started"
        @rpc_thread_id = params["threadId"] || params["thread_id"]
      when "turn/started"
        @turn_started_seen = true
        @state_machine.force_busy!
        emit_event("turn_started", turnId: params["turnId"] || params["turn_id"])
      when "turn/completed"
        @last_completed_at = Time.now
        @state_machine.force_prompt!
        payload = { turnId: params["turnId"] || params["turn_id"] }
        payload[:status] = params["status"] if params["status"]
        payload[:tokenUsage] = params["tokenUsage"] if params["tokenUsage"]
        emit_event("task_complete", **payload)
        schedule_auto_stop("task_complete", turn_id: payload[:turnId])
      when "item/completed"
        emit_event("item_completed", item: params["item"])
        text = render_item_text(params["item"])
        record_synthesized(text) if text
      when "thread/compacted"
        emit_event("compaction", **params)
      when "thread/tokenUsage/updated"
        # Surfaced via status fields in Phase 4; no event spam.
        @token_usage = params["usage"] || params
      when "thread/status/changed"
        # State machine reflects RPC state; no event needed.
        nil
      when "account/rateLimits/updated"
        @rate_limits = params
      when "error"
        @state_machine.force_busy!
        emit_event("disconnected", source: "error_notification", message: params["message"])
        signal_rpc_done!
      end
    rescue StandardError => e
      warn("harnex: rpc notification handler error: #{e.message}")
    end

    def handle_rpc_disconnect(error)
      msg = error.is_a?(Hash) ? error["message"] : error&.message
      @state_machine.force_busy!
      emit_event("disconnected", source: "transport", message: msg) rescue nil
      signal_rpc_done!
    end

    def dispatch_initial_prompt
      return unless adapter.respond_to?(:initial_prompt)

      prompt = adapter.initial_prompt
      return if prompt.to_s.empty?

      inject_via_jsonrpc(text: prompt, submit: true, enter_only: false, force: false)
    end

    def render_item_text(item)
      return nil unless item.is_a?(Hash)

      type = item["type"] || item["kind"]
      case type
      when "agent_message", "assistant_message"
        item["text"] || item.dig("message", "text")
      when "tool_call"
        name = item["name"] || item.dig("tool", "name") || "tool"
        params = item["params"] || item["arguments"]
        "tool: #{name}#{params ? " #{summarize(params)}" : ""}"
      else
        item["text"]
      end
    end

    def summarize(value)
      str = value.is_a?(String) ? value : JSON.generate(value)
      str.length > 120 ? "#{str[0, 117]}..." : str
    rescue StandardError
      ""
    end

    def record_synthesized(text)
      return if text.nil? || text.to_s.empty?

      payload = text.to_s.dup
      payload << "\n" unless payload.end_with?("\n")
      bytes = payload.b
      @mutex.synchronize do
        append_output_log(bytes)
        @output_buffer << bytes
        overflow = @output_buffer.bytesize - OUTPUT_BUFFER_LIMIT
        @output_buffer = @output_buffer.byteslice(overflow, OUTPUT_BUFFER_LIMIT) if overflow.positive?
      end
      begin
        STDOUT.write(payload)
        STDOUT.flush
      rescue StandardError
        nil
      end
    end

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
      old_state = @state_machine.to_s.to_sym
      new_state = @state_machine.update(snapshot)
      handle_auto_stop_pty_transition(old_state, new_state)
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

    def emit_git_start_event
      @git_start = Harnex.git_capture_start(repo_root)
      return if @git_start.empty?

      emit_event("git", phase: "start", sha: @git_start[:sha], branch: @git_start[:branch])
    end

    def emit_session_end_telemetry
      @usage_summary = normalized_usage_summary(adapter.parse_session_summary(transcript_tail))
      emit_event("usage", **@usage_summary)

      @git_end = Harnex.git_capture_end(repo_root, @git_start[:sha])
      return if @git_end.empty?

      emit_event(
        "git",
        phase: "end",
        sha: @git_end[:sha],
        loc_added: @git_end[:loc_added],
        loc_removed: @git_end[:loc_removed],
        files_changed: @git_end[:files_changed],
        commits: @git_end[:commits]
      )
    end

    def emit_summary_event
      emit_event("summary", path: summary_out, exit: @exit_reason)
    end

    def emit_exit_event
      payload = { code: @exit_code }
      payload[:signal] = @term_signal if @term_signal
      payload[:reason] = @exit_reason if @exit_reason
      emit_event("exited", **payload)
    end

    def stop_requested!
      @stop_mutex.synchronize do
        return true if @stop_requested

        @stop_requested = true
        false
      end
    end

    def arm_auto_stop_after_initial_context
      return unless @auto_stop
      return unless adapter.transport == :pty

      @auto_stop_mutex.synchronize { @auto_stop_seen_busy = true }
      @state_machine.force_busy!
    end

    def handle_auto_stop_pty_transition(old_state, new_state)
      return unless @auto_stop
      return unless adapter.transport == :pty

      seen_busy = @auto_stop_mutex.synchronize do
        @auto_stop_seen_busy ||= old_state == :busy || new_state == :busy
      end
      schedule_auto_stop("prompt_after_busy") if seen_busy && new_state == :prompt
    end

    def schedule_auto_stop(reason, turn_id: nil)
      return unless @auto_stop

      should_fire = @auto_stop_mutex.synchronize do
        if @auto_stop_fired
          false
        else
          @auto_stop_fired = true
          true
        end
      end
      return unless should_fire

      Thread.new do
        begin
          inject_stop(turn_id: turn_id)
        rescue StandardError => e
          warn("harnex: auto-stop failed after #{reason}: #{e.message}")
        end
      end
    end

    def classify_exit
      return "timeout" if @exit_code == 124
      return "success" if @exit_code == 0 && session_summary_present?
      return "boot_failure" if boot_failure_exit?
      return "failure" unless @exit_code == 0

      "disconnected"
    end

    def boot_failure_exit?
      return false unless adapter.transport == :stdio_jsonrpc
      return false if @turn_started_seen

      lifetime = (@ended_at || Time.now) - @started_at
      lifetime <= 5
    end

    def session_summary_present?
      @usage_summary.values.any? { |value| !value.nil? }
    end

    def build_summary_record
      {
        meta: build_summary_meta,
        predicted: summary_predicted_payload,
        actual: build_summary_actual
      }
    end

    def build_summary_meta
      info = Harnex.host_info
      passthrough = meta_hash

      {
        id: id,
        tmux_session: id,
        description: description,
        started_at: @started_at.iso8601,
        ended_at: @ended_at&.iso8601,
        harness: "harnex",
        harness_version: Harnex.harness_version,
        agent: adapter.key,
        agent_version: nil,
        agent_provider: nil,
        agent_deployment: nil,
        host: info[:host],
        platform: info[:platform],
        orchestrator: passthrough["orchestrator"],
        orchestrator_session: passthrough["orchestrator_session"],
        chain_id: passthrough["chain_id"],
        parent_dispatch_id: passthrough["parent_dispatch_id"],
        tier: passthrough["tier"],
        phase: passthrough["phase"],
        issue: passthrough["issue"],
        plan: passthrough["plan"],
        task_brief: passthrough["task_brief"],
        repo: repo_root,
        branch: @git_start[:branch],
        start_sha: @git_start[:sha],
        end_sha: @git_end[:sha]
      }
    end

    def build_summary_actual
      counters = @event_counters.snapshot
      if %w[disconnected boot_failure].include?(@exit_reason)
        counters[:disconnections] = [counters[:disconnections], 1].max
      end

      {
        model: meta_hash["model"],
        effort: meta_hash["effort"],
        duration_s: @ended_at ? (@ended_at - @started_at).to_i : nil,
        input_tokens: @usage_summary[:input_tokens],
        output_tokens: @usage_summary[:output_tokens],
        reasoning_tokens: @usage_summary[:reasoning_tokens],
        cached_tokens: @usage_summary[:cached_tokens],
        cost_usd: nil,
        loc_added: @git_end[:loc_added],
        loc_removed: @git_end[:loc_removed],
        files_changed: @git_end[:files_changed],
        commits: @git_end[:commits],
        exit: @exit_reason,
        stalls: counters[:stalls],
        force_resumes: counters[:force_resumes],
        disconnections: counters[:disconnections],
        compactions: counters[:compactions],
        tests_run: nil,
        tests_passed: nil,
        tests_failed: nil
      }
    end

    def summary_predicted_payload
      predicted = meta_hash["predicted"]
      predicted.is_a?(Hash) ? predicted : {}
    end

    def meta_hash
      meta.is_a?(Hash) ? meta : {}
    end

    def append_summary_record(record)
      return unless summary_out

      FileUtils.mkdir_p(File.dirname(summary_out))
      File.open(summary_out, "ab") do |file|
        file.write(JSON.generate(record))
        file.write("\n")
      end
    rescue StandardError => e
      warn("harnex: failed to write dispatch summary #{summary_out}: #{e.message}")
    end

    def normalized_usage_summary(summary)
      summary ||= {}
      USAGE_FIELDS.to_h { |field| [field, summary[field] || summary[field.to_s]] }
    end

    def transcript_tail
      return "" unless File.file?(output_log_path)

      File.open(output_log_path, "rb") do |file|
        size = file.size
        file.seek([size - TRANSCRIPT_TAIL_BYTES, 0].max)
        Harnex.strip_ansi(file.read.to_s)
      end
    rescue StandardError
      ""
    end

    def emit_event(type, **payload)
      @event_counters.record(type)
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
