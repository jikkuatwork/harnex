require "io/console"
require "json"
require "pty"

module Harnex
  class Session
    OUTPUT_BUFFER_LIMIT = 64 * 1024
    TRANSCRIPT_TAIL_BYTES = 16 * 1024
    AUTOSTOP_TEARDOWN_GRACE_SECONDS_DEFAULT = 5.0
    USAGE_FIELDS = %i[
      input_tokens output_tokens reasoning_tokens cached_tokens total_tokens
      agent_session_id cost_usd tool_calls model agent_provider
    ].freeze
    SESSION_SUMMARY_SIGNAL_FIELDS = %i[
      input_tokens output_tokens reasoning_tokens cached_tokens total_tokens
      agent_session_id cost_usd
    ].freeze
    BUDGET_META_FIELDS = %w[read_budget_lines output_ceiling_lines].freeze
    SUCCESSFUL_TURN_STATUSES = %w[completed success succeeded].freeze
    class EventCounters
      def initialize
        @counts = {
          stalls: 0,
          force_resumes: 0,
          disconnections: 0,
          compactions: 0,
          tool_calls: 0,
          commands_executed: 0
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

      def record_item(item)
        return unless item.is_a?(Hash)

        case item["type"]
        when "mcpToolCall", "dynamicToolCall"
          @counts[:tool_calls] += 1
        when "commandExecution"
          @counts[:commands_executed] += 1
        end
      end

      def snapshot
        @counts.dup
      end
    end

    attr_reader :repo_root, :launch_cwd, :child_cwd, :host, :port, :session_id, :token, :command, :pid, :id, :adapter, :watch,
                :inbox, :description, :meta, :summary_out, :output_log_path, :events_log_path,
                :started_at, :ended_at, :exit_code, :term_signal

    def initialize(adapter:, command:, repo_root:, host:, port: nil, id: DEFAULT_ID, watch: nil, description: nil, meta: nil, summary_out: nil, inbox_ttl: Inbox::DEFAULT_TTL, auto_stop: false, launch_cwd: nil, child_cwd: nil)
      @adapter = adapter
      @command = command
      @repo_root = repo_root
      @launch_cwd = File.expand_path(launch_cwd.to_s.empty? ? repo_root : launch_cwd)
      @child_cwd = child_cwd.to_s.empty? ? nil : File.expand_path(child_cwd)
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
      @last_error = nil
      @session_finalized = false
      @turn_started_seen = false
      @last_completed_at = nil
      @last_failed_at = nil
      @last_failed_status = nil
      @pi_streamed_text_by_message = {}
      @auto_stop = !!auto_stop
      @auto_stop_fired = false
      @auto_stop_seen_busy = false
      @auto_stop_threads = []
      @stop_requested = false
      @writer = nil
      @pid = nil
      @term_signal = nil
      @output_buffer = +""
      @output_buffer.force_encoding(Encoding::BINARY)
      @state_machine = SessionState.new(adapter)
      @inbox = Inbox.new(self, @state_machine, ttl: inbox_ttl)
      @rate_limits = nil
      @parent_harnex_id = ENV["HARNEX_ID"].to_s.strip
      @parent_harnex_id = nil if @parent_harnex_id.empty?
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

      return run_structured if structured_transport?

      run_pty
    end

    def run_pty
      spawn_args = [child_env, *command]
      spawn_args << { chdir: child_cwd } if child_cwd
      @reader, @writer, @pid = PTY.spawn(*spawn_args)
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

      normalize_auto_stop_exit_code!
      drain_auto_stop_threads
      output_thread.join(1)
      finalize_session!
      input_thread&.kill
      watch_thread&.kill
      @exit_code
    ensure
      finalize_session!
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
      task_complete = task_complete?
      task_failed = task_failed?
      work_state = task_failed ? "failed" : Harnex.work_state_for("running", task_complete: task_complete)
      payload[:agent_state] = @state_machine.to_s
      payload[:process_state] = "running"
      payload[:inbox] = @inbox.stats
      payload[:last_completed_at] = @last_completed_at&.iso8601
      payload[:last_failed_at] = @last_failed_at&.iso8601
      payload[:task_complete] = task_complete
      payload[:task_failed] = task_failed
      payload[:done] = Harnex.work_done_for("running", task_complete: task_complete)
      payload[:work_state] = work_state
      payload[:last_error] = @last_error
      payload[:model] = summary_model
      payload[:effort] = meta_hash["effort"]
      payload[:auto_disconnects] = @event_counters.snapshot[:disconnections]
      payload
    end

    def task_complete?
      !!@last_completed_at && !task_failed?
    end

    def task_failed?
      !!@last_failed_at
    end

    def git_start
      @git_start || {}
    end

    def git_end
      @git_end || {}
    end

    def auth_ok?(header)
      header == "Bearer #{token}"
    end

    def inject(text, newline: true)
      raise "session is not running" unless pid && Harnex.alive_pid?(pid)

      inject_sequence([{ text: text, newline: newline }])
    end

    def inject_stop(turn_id: nil, interrupt: true)
      unless structured_transport?
        raise "session is not running" unless pid && Harnex.alive_pid?(pid)
      end

      return { ok: true, signal: "already_requested" } if stop_requested!

      if structured_transport?
        if adapter.respond_to?(:terminate_subprocess)
          Thread.new do
            begin
              adapter.terminate_subprocess
            rescue Errno::ESRCH, StandardError
              nil
            end
          end
        end
        if interrupt
          @inject_mutex.synchronize do
            begin
              adapter.interrupt(turn_id: turn_id)
            rescue StandardError
              nil
            end
            @state_machine.force_busy!
          end
          return { ok: true, signal: "interrupt_sent" }
        end

        @state_machine.force_busy!
        signal_rpc_done! unless @pid
        return { ok: true, signal: "terminate_sent" }
      end

      @inject_mutex.synchronize do
        adapter.inject_exit(@writer)
        @state_machine.force_busy!
      end

      { ok: true, signal: "exit_sequence_sent" }
    end

    def inject_via_adapter(text:, submit:, enter_only:, force: false)
      if structured_transport?
        return inject_via_structured(text: text, submit: submit, enter_only: enter_only, force: force)
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

    def inject_via_structured(text:, submit:, enter_only:, force: false)
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
        begin
          turn_id = adapter.dispatch(**dispatch)
        rescue StandardError => e
          mark_task_failed(status: "dispatch_error", error: e.message)
          raise
        end
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

    def structured_transport?
      %i[stdio_jsonrpc stdio_jsonl_rpc].include?(adapter.transport)
    end

    def run_structured
      adapter.on_notification { |msg| handle_structured_notification(msg) }
      adapter.on_disconnect { |err| handle_structured_disconnect(err) }

      adapter.start_rpc(env: child_env, cwd: child_cwd || repo_root)
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

      normalize_auto_stop_exit_code!
      drain_auto_stop_threads
      finalize_session!
      watch_thread&.kill
      @exit_code
    ensure
      finalize_session!
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

    alias run_jsonrpc run_structured

    def signal_rpc_done!
      @rpc_done = true
      if defined?(@rpc_done_lock) && @rpc_done_lock
        @rpc_done_lock.synchronize { @rpc_done_cond&.signal }
      end
    end

    def handle_structured_notification(message)
      case adapter.transport
      when :stdio_jsonrpc
        handle_rpc_notification(message)
      when :stdio_jsonl_rpc
        handle_jsonl_notification(message)
      end
    end

    def handle_rpc_notification(message)
      method = message["method"]
      params = message["params"] || {}

      case method
      when "thread/started"
        @rpc_thread_id = params.dig("thread", "id")
      when "turn/started"
        @turn_started_seen = true
        @state_machine.force_busy!
        emit_event("turn_started", turnId: params.dig("turn", "id"))
      when "turn/completed"
        @state_machine.force_prompt!
        turn = params["turn"] || {}
        status = turn["status"]
        turn_id = turn["id"] || params["turnId"]
        payload = { turnId: turn_id }
        payload[:status] = status if status
        payload[:tokenUsage] = params["tokenUsage"] if params["tokenUsage"].is_a?(Hash)
        if successful_turn_status?(status)
          @last_completed_at = Time.now
          emit_event("task_complete", **payload)
        else
          mark_task_failed(
            turn_id: turn_id,
            status: status,
            error: extract_turn_error_message(turn),
            codex_error_info: extract_turn_error_info(turn)
          )
        end
        schedule_auto_stop("turn_completed", interrupt: false)
      when "item/completed"
        emit_event("item_completed", item: params["item"])
        @event_counters.record_item(params["item"])
        text = render_item_text(params["item"])
        record_synthesized(text) if text
      when "thread/compacted"
        emit_event("compaction", **params)
      when "thread/tokenUsage/updated"
        # Schema: ThreadTokenUsageUpdatedNotification carries
        # `tokenUsage: { last, total, modelContextWindow? }` where each
        # breakdown has camelCase {input,output,cachedInput,reasoningOutput,total}Tokens.
        # Snapshot it; the cumulative `total` is read at session end.
        @token_usage = params["tokenUsage"] if params["tokenUsage"].is_a?(Hash)
      when "thread/status/changed"
        # State machine reflects RPC state; no event needed.
        nil
      when "account/rateLimits/updated"
        @rate_limits = params
      when "error"
        message = extract_error_notification_message(params)
        @last_error = message unless message.to_s.empty?
        @state_machine.force_busy!
        emit_event(
          "error",
          source: "error_notification",
          message: message,
          codex_error_info: extract_error_notification_info(params),
          will_retry: params["willRetry"],
          threadId: params["threadId"],
          turnId: params["turnId"]
        )
        signal_rpc_done! if params["turnId"].to_s.empty?
      end
    rescue StandardError => e
      warn("harnex: rpc notification handler error: #{e.message}")
    end

    def successful_turn_status?(status)
      text = status.to_s
      return true if text.empty?

      SUCCESSFUL_TURN_STATUSES.include?(text)
    end

    def mark_task_failed(turn_id: nil, status: nil, error: nil, codex_error_info: nil)
      @last_failed_at = Time.now
      @last_failed_status = status.to_s.empty? ? "failed" : status.to_s
      @last_error = error.to_s unless error.to_s.empty?

      payload = { status: @last_failed_status }
      payload[:turnId] = turn_id if turn_id
      payload[:message] = error unless error.to_s.empty?
      payload[:codex_error_info] = codex_error_info if codex_error_info
      emit_event("task_failed", **payload)
    end

    def extract_error_notification_message(params)
      error = params["error"]
      if error.is_a?(Hash)
        error["message"] || error.dig("error", "message") || params["message"]
      else
        params["message"]
      end
    end

    def extract_error_notification_info(params)
      error = params["error"]
      error.is_a?(Hash) ? error["codexErrorInfo"] : nil
    end

    def extract_turn_error_message(turn)
      error = turn["error"]
      return error["message"] if error.is_a?(Hash)
      return error if error.is_a?(String)

      nil
    end

    def extract_turn_error_info(turn)
      error = turn["error"]
      error.is_a?(Hash) ? error["codexErrorInfo"] : nil
    end

    def handle_jsonl_notification(message)
      event_type = message["type"].to_s

      case event_type
      when "agent_start", "turn_start"
        @turn_started_seen = true if event_type == "turn_start"
        @state_machine.force_busy!
        emit_event("turn_started") if event_type == "turn_start"
      when "agent_end"
        @last_completed_at = Time.now
        @state_machine.force_prompt!
        emit_event("task_complete")
        adapter.request_session_stats_async if adapter.respond_to?(:request_session_stats_async)
        schedule_auto_stop("task_complete", interrupt: false)
      when "message_start"
        @pi_streamed_text_by_message[pi_message_key(message["message"])] = false
      when "message_update"
        event = message["assistantMessageEvent"] || {}
        delta = event["delta"]
        key = pi_message_key(message["message"])
        if event["type"] == "text_delta" && delta && !delta.empty?
          @pi_streamed_text_by_message[key] = true
          record_synthesized(delta, newline: false)
        end
      when "message_end"
        key = pi_message_key(message["message"])
        streamed = @pi_streamed_text_by_message.delete(key)
        unless streamed
          text = pi_extract_message_text(message["message"])
          record_synthesized(text) if text
        end
      when "tool_execution_start"
        @event_counters.record_item({ "type" => "dynamicToolCall" })
        record_synthesized(
          "tool: #{message["toolName"] || "tool"}#{message["args"] ? " #{summarize(message["args"])}" : ""}"
        )
      when "tool_execution_end"
        tool_name = message["toolName"] || "tool"
        status = message["isError"] ? "error" : "ok"
        record_synthesized("tool-result: #{tool_name} (#{status})")
      when "compaction_start", "compaction_end"
        emit_event("compaction", reason: message["reason"], phase: event_type)
      when "queue_update"
        nil
      when "auto_retry_start", "auto_retry_end"
        emit_event(event_type, **message.reject { |k, _| k == "type" })
      when "extension_ui_request"
        handle_extension_ui_request(message)
      when "extension_error"
        @last_error = message["error"].to_s unless message["error"].to_s.empty?
        emit_event("extension_error", **message.reject { |k, _| k == "type" })
      when "response"
        # Adapter-level command responses are handled in the adapter.
        nil
      end
    rescue StandardError => e
      warn("harnex: rpc notification handler error: #{e.message}")
    end

    def handle_extension_ui_request(message)
      method = message["method"].to_s
      request_id = message["id"]
      cancelled = false
      if adapter.respond_to?(:respond_extension_ui_cancel)
        cancelled = adapter.respond_extension_ui_cancel(request_id: request_id, method: method)
      end

      payload = {
        method: method,
        request_id: request_id,
        auto_cancelled: !!cancelled
      }
      emit_event("extension_ui_request", **payload)
      record_synthesized("extension-ui: #{method}#{cancelled ? " (auto-cancelled)" : ""}")
    end

    def handle_structured_disconnect(error)
      handle_rpc_disconnect(error)
    end

    def handle_rpc_disconnect(error)
      msg = error.is_a?(Hash) ? error["message"] : error&.message
      if normal_auto_stop_disconnect?(msg)
        signal_rpc_done!
        return
      end

      @last_error = msg.to_s unless msg.to_s.empty?
      @state_machine.force_busy!
      emit_event("disconnected", source: "transport", message: msg) rescue nil
      signal_rpc_done!
    end

    def normal_auto_stop_disconnect?(message)
      message.to_s.empty? && @auto_stop_fired && (task_complete? || task_failed?)
    end

    def dispatch_initial_prompt
      return unless adapter.respond_to?(:initial_prompt)

      prompt = adapter.initial_prompt
      return if prompt.to_s.empty?

      inject_via_structured(text: prompt, submit: true, enter_only: false, force: false)
    end

    def render_item_text(item)
      return nil unless item.is_a?(Hash)

      case item["type"]
      when "agentMessage"
        item["text"]
      when "mcpToolCall", "dynamicToolCall"
        name = item["tool"] || "tool"
        args = item["arguments"]
        "tool: #{name}#{args ? " #{summarize(args)}" : ""}"
      when "commandExecution"
        "command: #{item["command"]}"
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

    def pi_extract_message_text(message)
      return nil unless message.is_a?(Hash)

      content = message["content"]
      case content
      when String
        content
      when Array
        parts = content.filter_map do |item|
          next unless item.is_a?(Hash)
          next unless item["type"] == "text"

          item["text"].to_s
        end
        parts.empty? ? nil : parts.join
      else
        nil
      end
    end

    def pi_message_key(message)
      return "unknown" unless message.is_a?(Hash)

      message["entryId"] || message["id"] || message["timestamp"] || message.object_id
    end

    def record_synthesized(text, newline: true)
      return if text.nil? || text.to_s.empty?

      payload = text.to_s.dup
      payload << "\n" if newline && !payload.end_with?("\n")
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
        cwd: child_cwd || Dir.pwd
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
      task_complete = task_complete?
      task_failed = task_failed?
      state = task_failed || @exit_code.to_i != 0 ? "failed" : "completed"
      payload = {
        ok: !task_failed && state == "completed",
        id: id,
        cli: adapter.key,
        session_id: session_id,
        repo_root: repo_root,
        exit_code: @exit_code,
        state: state,
        process_state: "exited",
        task_complete: task_complete,
        task_failed: task_failed,
        done: Harnex.work_done_for(state, task_complete: task_complete),
        work_state: Harnex.work_state_for(state, task_complete: task_complete),
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
      @usage_summary = normalized_usage_summary(collect_session_summary)
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

    def finalize_session!
      return if @session_finalized
      return unless @events_log

      @session_finalized = true
      @ended_at ||= Time.now
      begin
        emit_session_end_telemetry
      rescue StandardError => e
        @usage_summary = normalized_usage_summary(nil)
        warn("harnex: failed to collect session-end telemetry: #{e.message}")
      end
      @exit_reason ||= classify_exit
      append_summary_record(build_summary_record)
      append_dispatch_history_record
      emit_summary_event
      emit_exit_event
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

    def schedule_auto_stop(reason, turn_id: nil, interrupt: true)
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

      thread = Thread.new do
        begin
          inject_stop(turn_id: turn_id, interrupt: interrupt)
        rescue StandardError => e
          warn("harnex: auto-stop failed after #{reason}: #{e.message}")
        end
      end
      track_auto_stop_thread(thread)
    end

    def track_auto_stop_thread(thread)
      @auto_stop_mutex.synchronize { @auto_stop_threads << thread }
    end

    def drain_auto_stop_threads
      return unless @auto_stop

      threads = @auto_stop_mutex.synchronize { @auto_stop_threads.dup }
      return if threads.empty?

      grace_seconds = auto_stop_teardown_grace_seconds
      deadline = Time.now + grace_seconds
      timed_out = []

      threads.each do |thread|
        remaining = deadline - Time.now
        thread.join(remaining) if remaining.positive?
        timed_out << thread if thread.alive?
      end
      return if timed_out.empty?

      timed_out.each(&:kill)
      @exit_code = 1 if @exit_code.nil? || @exit_code.zero?
      @term_signal = nil if @exit_code == 1
      emit_event("auto_stop_teardown_timeout", grace_seconds: grace_seconds, threads: timed_out.size)
    end

    def auto_stop_teardown_grace_seconds
      override = ENV["HARNEX_AUTOSTOP_TEARDOWN_GRACE_SECONDS"]
      return AUTOSTOP_TEARDOWN_GRACE_SECONDS_DEFAULT if override.to_s.strip.empty?

      Float(override)
    rescue ArgumentError
      AUTOSTOP_TEARDOWN_GRACE_SECONDS_DEFAULT
    end

    def normalize_auto_stop_exit_code!
      return unless @auto_stop
      return unless @auto_stop_fired

      if task_failed?
        @exit_code = 1 if @exit_code.nil? || @exit_code.zero? || @term_signal
        @term_signal = nil if @exit_code == 1
        return
      end

      return unless task_complete?

      @exit_code = 0
      @term_signal = nil
    end

    def classify_exit
      return "timeout" if @exit_code == 124
      return "boot_failure" if boot_failure_exit?
      return "failure" if task_failed?
      return "success" if @exit_code == 0 && task_complete?
      return "success" if @exit_code == 0 && session_summary_present?
      return "failure" unless @exit_code == 0

      "disconnected"
    end

    def boot_failure_exit?
      return false unless structured_transport?
      return false if @turn_started_seen

      lifetime = (@ended_at || Time.now) - @started_at
      lifetime <= 5
    end

    def session_summary_present?
      SESSION_SUMMARY_SIGNAL_FIELDS.any? { |field| !@usage_summary[field].nil? }
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
        tmux_session: summary_tmux_session,
        description: description,
        started_at: @started_at.iso8601,
        ended_at: @ended_at&.iso8601,
        harness: "harnex",
        harness_version: Harnex.harness_version,
        agent: adapter.key,
        agent_version: adapter.agent_version,
        agent_provider: summary_agent_provider,
        host: info[:host],
        platform: info[:platform],
        orchestrator: passthrough["orchestrator"],
        orchestrator_session: passthrough["orchestrator_session"],
        chain_id: passthrough["chain_id"],
        parent_dispatch_id: passthrough["parent_dispatch_id"] || @parent_harnex_id,
        tier: passthrough["tier"],
        phase: passthrough["phase"],
        issue: passthrough["issue"],
        plan: passthrough["plan"],
        task_brief: passthrough["task_brief"],
        repo: repo_root,
        branch: @git_start[:branch],
        start_sha: @git_start[:sha],
        end_sha: @git_end[:sha]
      }.merge(summary_budget_meta)
    end

    def build_summary_actual
      counters = @event_counters.snapshot
      output_measurements = summary_output_measurements
      if %w[disconnected boot_failure].include?(@exit_reason)
        counters[:disconnections] = [counters[:disconnections], 1].max
      end

      actual = {
        model: summary_model,
        effort: meta_hash["effort"],
        duration_s: @ended_at ? (@ended_at - @started_at).to_i : nil,
        input_tokens: @usage_summary[:input_tokens],
        output_tokens: @usage_summary[:output_tokens],
        reasoning_tokens: @usage_summary[:reasoning_tokens],
        cached_tokens: @usage_summary[:cached_tokens],
        total_tokens: @usage_summary[:total_tokens],
        cost_usd: @usage_summary[:cost_usd],
        agent_session_id: summary_agent_session_id,
        adapter_transport: adapter.transport.to_s,
        loc_added: @git_end[:loc_added],
        loc_removed: @git_end[:loc_removed],
        lines_changed: summary_lines_changed,
        files_changed: @git_end[:files_changed],
        commits: @git_end[:commits],
        exit: @exit_reason,
        task_complete: task_complete?,
        signal: @term_signal,
        exit_code: @exit_code,
        last_error: @last_error,
        stalls: counters[:stalls],
        force_resumes: counters[:force_resumes],
        disconnections: counters[:disconnections],
        compactions: counters[:compactions],
        turn_count: @injected_count,
        tool_calls: summary_tool_calls(counters),
        commands_executed: counters[:commands_executed],
        rate_limits: @rate_limits,
        output_lines: output_measurements[:lines],
        output_bytes: output_measurements[:bytes],
        event_records: @events_log_seq,
        output_log_path: output_log_path,
        events_log_path: events_log_path
      }
      actual
    end

    def summary_budget_meta
      BUDGET_META_FIELDS.each_with_object({}) do |field, values|
        values[field.to_sym] = meta_hash[field] if meta_hash.key?(field)
      end
    end

    def summary_lines_changed
      added = @git_end[:loc_added]
      removed = @git_end[:loc_removed]
      return nil if added.nil? && removed.nil?

      added.to_i + removed.to_i
    end

    def summary_output_measurements
      size = File.size?(output_log_path)
      return { lines: nil, bytes: nil } unless size

      lines = 0
      File.foreach(output_log_path) { lines += 1 }
      { lines: lines, bytes: size }
    rescue StandardError
      { lines: nil, bytes: size }
    end

    def summary_tmux_session
      value = load_existing_registry_metadata["tmux_session"]
      value.to_s.empty? ? nil : value
    end

    def summary_agent_session_id
      @usage_summary[:agent_session_id] ||
        @rpc_thread_id ||
        (adapter.thread_id if adapter.respond_to?(:thread_id))
    end

    def summary_agent_provider
      @usage_summary[:agent_provider] || adapter.provider
    end

    def summary_model
      meta_hash["model"] || @usage_summary[:model] ||
        (adapter.current_model if adapter.respond_to?(:current_model))
    end

    def summary_tool_calls(counters)
      @usage_summary[:tool_calls] || counters[:tool_calls]
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

    def append_dispatch_history_record
      path = DispatchHistory.path_for(launch_cwd)
      DispatchHistory.append(path, DispatchHistory.build_record(self))
    rescue StandardError => e
      warn("harnex: failed to write dispatch history: #{e.message}")
    end

    def normalized_usage_summary(summary)
      summary ||= {}
      USAGE_FIELDS.to_h { |field| [field, summary[field] || summary[field.to_s]] }
    end

    # Structured adapters emit usage directly (JSON-RPC token snapshots,
    # Pi RPC stats). PTY adapters parse transcript tails when supported.
    def collect_session_summary
      if adapter.transport == :stdio_jsonrpc
        summary_from_token_usage
      elsif adapter.respond_to?(:collect_session_summary)
        adapter.collect_session_summary
      else
        adapter.parse_session_summary(transcript_tail)
      end
    end

    def summary_from_token_usage
      return {} unless @token_usage.is_a?(Hash)

      total = @token_usage["total"]
      return {} unless total.is_a?(Hash)

      {
        input_tokens: total["inputTokens"],
        output_tokens: total["outputTokens"],
        reasoning_tokens: total["reasoningOutputTokens"],
        cached_tokens: total["cachedInputTokens"],
        total_tokens: total["totalTokens"]
      }
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
        return if @events_log.closed?

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
