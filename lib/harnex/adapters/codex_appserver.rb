require "json"
require "open3"

module Harnex
  module Adapters
    # Codex `app-server` adapter — JSON-RPC over stdio.
    #
    # Talks to a spawned `codex app-server` subprocess by writing
    # newline-delimited JSON-RPC messages on stdin and reading
    # responses + notifications from stdout. Replaces the pane-scraping
    # heuristics in `Adapters::Codex` (legacy, kept behind --legacy-pty).
    class CodexAppServer < Base
      CLIENT_TITLE = "harnex"
      CLIENT_NAME = "harnex"

      OPT_OUT_NOTIFICATIONS = %w[
        item/agentMessage/delta
        item/reasoning/summaryTextDelta
        item/reasoning/summaryPartAdded
        item/reasoning/textDelta
      ].freeze

      REQUEST_METHODS = %w[
        initialize thread/start turn/start turn/interrupt thread/resume
      ].freeze

      NOTIFICATION_METHODS = %w[
        thread/started turn/started turn/completed
        item/started item/completed
        thread/status/changed thread/tokenUsage/updated
        thread/compacted account/rateLimits/updated
        error
      ].freeze

      EVENTS = %w[task_complete turn_started item_completed disconnected].freeze
      STOP_TERM_GRACE_SECONDS = 0.5
      STOP_KILL_GRACE_SECONDS = 1.0

      # Server→client approval requests harnex auto-approves so dispatched
      # codex workers can run autonomously. Codex sends these via JSON-RPC
      # when its sandbox/approval policy needs a client decision; without
      # a handler the client returns -32601 and codex blocks the operation.
      # Permissions / user-input / dynamic-tool / auth-refresh requests
      # have richer response shapes and are deliberately not auto-handled
      # — they fall through to -32601 until a use case appears.
      APPROVAL_RESPONSES = {
        "applyPatchApproval"                    => { decision: "approved" },
        "execCommandApproval"                   => { decision: "approved" },
        "item/commandExecution/requestApproval" => { decision: "approved" },
        "item/fileChange/requestApproval"       => { decision: "accept" }
      }.freeze

      attr_reader :thread_id, :current_turn_id, :last_completed_at, :initial_prompt

      def initialize(extra_args = [])
        super("codex", extra_args)
        @initial_prompt = extract_initial_prompt(extra_args)
        @client = nil
        @thread_id = nil
        @current_turn_id = nil
        @state = :disconnected
        @last_completed_at = nil
        @notification_handler = nil
        @disconnect_handler = nil
      end

      def transport
        :stdio_jsonrpc
      end

      def base_command
        ["codex", "app-server"]
      end

      # The harnex-context entry (set by `--context`) is delivered via
      # JSON-RPC `turn/start`, not as a CLI argument — codex app-server
      # rejects positional input and would exit immediately. Operator-
      # supplied codex flags (passed via `harnex run codex -- ...`) are
      # appended so e.g. `-c sandbox_mode=danger-full-access` works.
      def build_command
        base_command + cli_extra_args
      end

      def describe
        {
          transport: transport,
          request_methods: REQUEST_METHODS,
          notification_methods: NOTIFICATION_METHODS,
          events: EVENTS
        }
      end

      def state
        @state
      end

      # Override: state is RPC-driven, screen text is ignored.
      def input_state(_screen_text = nil)
        {
          state: @state.to_s,
          input_ready: @state == :prompt
        }
      end

      def build_send_payload(text:, submit:, enter_only:, screen_text:, force: false)
        state = input_state(nil)
        if !force && submit && !enter_only && state[:input_ready] != true
          raise ArgumentError, blocked_message(state, enter_only: enter_only)
        end
        raise ArgumentError, "Codex app-server cannot stage input without submitting it" unless submit || enter_only
        raise ArgumentError, "Codex app-server does not support submit-only input" if enter_only

        {
          dispatch: { prompt: text.to_s },
          input_state: state,
          force: force
        }
      end

      # No-op: closing the subprocess is handled via #close.
      def inject_exit(_writer, **_kwargs)
        nil
      end

      def on_notification(&block)
        @notification_handler = block
      end

      def on_disconnect(&block)
        @disconnect_handler = block
      end

      # Start the JSON-RPC client. In production, spawns the codex
      # subprocess. In tests, callers may pass pre-built IO objects.
      def start_rpc(env: nil, cwd: nil, read_io: nil, write_io: nil, pid: nil)
        if read_io && write_io
          @client = JsonRpcClient.new(read_io: read_io, write_io: write_io, pid: pid)
        else
          spawn_pid, child_stdin, child_stdout = spawn_subprocess(env, cwd)
          @client = JsonRpcClient.new(read_io: child_stdout, write_io: child_stdin, pid: spawn_pid)
        end

        @client.on_notification { |msg| handle_notification(msg) }
        @client.on_request { |method, params| handle_server_request(method, params) }
        @client.on_disconnect { |err| handle_disconnect(err) }
        @client.start
        perform_handshake
        @state = :prompt
        self
      end

      # Auto-approve known approval-style requests so dispatched workers
      # can run without a human-in-the-loop. Returns the response body to
      # serialize as JSON-RPC `result`, or `nil` to fall through to -32601.
      def handle_server_request(method, _params)
        APPROVAL_RESPONSES[method]
      end

      def dispatch(prompt:, model: nil, effort: nil)
        ensure_open!
        ensure_thread!
        params = {
          threadId: @thread_id,
          input: [{ type: "text", text: prompt.to_s }]
        }
        params[:model] = model if model
        params[:effort] = effort if effort

        result = @client.request("turn/start", params)
        @current_turn_id = result["turnId"] || result["turn_id"] || result["id"]
        @state = :busy
        @current_turn_id
      end

      def interrupt(turn_id: nil)
        ensure_open!
        target = turn_id || @current_turn_id
        return nil if target.nil?

        @client.request("turn/interrupt", { threadId: @thread_id, turnId: target })
      end

      def resume(thread_id:)
        ensure_open!
        result = @client.request("thread/resume", { threadId: thread_id })
        @thread_id = thread_id
        @state = :prompt
        result
      end

      def close
        return unless @client

        @client.close
        @client = nil
        @state = :disconnected
      end

      def terminate_subprocess(term_grace_seconds: STOP_TERM_GRACE_SECONDS, kill_grace_seconds: STOP_KILL_GRACE_SECONDS)
        @client&.terminate_process(
          term_grace_seconds: term_grace_seconds,
          kill_grace_seconds: kill_grace_seconds
        )
      end

      def pid
        @client&.pid
      end

      private

      def ensure_open!
        raise "codex_appserver: client not started" unless @client
        raise "codex_appserver: disconnected" if @state == :disconnected
      end

      def ensure_thread!
        return if @thread_id

        result = @client.request("thread/start", {})
        @thread_id = extract_thread_id(result)
      end

      def extract_thread_id(payload)
        return nil unless payload.is_a?(Hash)

        payload.dig("thread", "id") || payload["threadId"] || payload["thread_id"]
      end

      def extract_initial_prompt(extra_args)
        return nil unless extra_args.is_a?(Array)

        prefixed = extra_args.find { |a| a.is_a?(String) && a.start_with?("[harnex session id=") }
        return prefixed if prefixed && !prefixed.empty?

        nil
      end

      # Codex CLI flags only — strips the harnex-context entry that
      # `--context` smuggles through @extra_args.
      def cli_extra_args
        @extra_args.reject { |a| a.is_a?(String) && a.start_with?("[harnex session id=") }
      end

      def perform_handshake
        @client.request("initialize", {
          clientInfo: {
            title: CLIENT_TITLE,
            name: CLIENT_NAME,
            version: Harnex::VERSION
          },
          capabilities: {
            experimentalApi: false,
            optOutNotificationMethods: OPT_OUT_NOTIFICATIONS
          }
        })
        @client.notify("initialized", {})
      end

      def handle_notification(message)
        method = message["method"]
        params = message["params"] || {}

        case method
        when "thread/started"
          @thread_id ||= extract_thread_id(params)
        when "turn/started"
          @current_turn_id = params["turnId"] || params["turn_id"]
          @state = :busy
        when "turn/completed"
          @last_completed_at = Time.now
          @current_turn_id = nil
          @state = :prompt
        when "error"
          @state = :disconnected
        end

        @notification_handler&.call(message)
      end

      def handle_disconnect(error)
        @state = :disconnected
        @disconnect_handler&.call(error)
      end

      def spawn_subprocess(env, cwd)
        spawn_env = env || {}
        opts = {}
        opts[:chdir] = cwd if cwd
        stdin_io, stdout_io, _stderr_io, wait_thr =
          Open3.popen3(spawn_env, *build_command, **opts)
        [wait_thr.pid, stdin_io, stdout_io]
      end

      def blocked_message(state, enter_only:)
        return super if enter_only

        "Codex app-server is not at a prompt; wait and retry or use `harnex send --force` (state: #{state[:state]})"
      end

      # Minimal JSON-RPC 2.0 client. One JSON object per line.
      # Responses keyed by id; everything else is a notification.
      class JsonRpcClient
        attr_reader :pid

        def initialize(read_io:, write_io:, pid: nil)
          @read_io = read_io
          @write_io = write_io
          @pid = pid
          @next_id = 1
          @pending = {}
          @id_mutex = Mutex.new
          @write_mutex = Mutex.new
          @notification_handler = nil
          @request_handler = nil
          @disconnect_handler = nil
          @disconnect_signaled = false
          @closed = false
          @reader_thread = nil
        end

        def on_notification(&block)
          @notification_handler = block
        end

        # Handler for server-initiated requests (id + method). The block
        # receives (method, params) and returns the response body for the
        # JSON-RPC `result` field, or nil to reject with -32601.
        def on_request(&block)
          @request_handler = block
        end

        def on_disconnect(&block)
          @disconnect_handler = block
        end

        def start
          @reader_thread = Thread.new { read_loop }
        end

        def request(method, params = {})
          raise "codex_appserver client is closed" if @closed

          queue = Queue.new
          id = @id_mutex.synchronize do
            assigned = @next_id
            @next_id += 1
            @pending[assigned] = queue
            assigned
          end

          write_line({ jsonrpc: "2.0", id: id, method: method, params: params })
          result = queue.pop
          raise result if result.is_a?(Exception)

          result
        end

        def notify(method, params = {})
          return if @closed

          write_line({ jsonrpc: "2.0", method: method, params: params })
        end

        def close
          return if @closed

          @closed = true

          @id_mutex.synchronize do
            @pending.each_value { |q| q.push(StandardError.new("codex_appserver client closed")) }
            @pending.clear
          end

          begin
            @write_io.close unless @write_io.closed?
          rescue IOError
            nil
          end

          if @pid && process_alive?(@pid)
            sleep 0.05
            begin
              Process.kill("TERM", @pid)
            rescue Errno::ESRCH
              nil
            end
          end

          @reader_thread&.join(2)
        end

        def terminate_process(term_grace_seconds:, kill_grace_seconds:)
          return false unless @pid

          begin
            Process.kill("TERM", @pid)
          rescue Errno::ESRCH
            return true
          end

          return true if wait_for_process_exit(@pid, term_grace_seconds)

          begin
            Process.kill("KILL", @pid)
          rescue Errno::ESRCH
            return true
          end

          wait_for_process_exit(@pid, kill_grace_seconds)
        end

        private

        def write_line(message)
          @write_mutex.synchronize do
            @write_io.write(JSON.generate(message))
            @write_io.write("\n")
            @write_io.flush
          end
        rescue Errno::EPIPE, IOError
          signal_disconnect(nil)
        end

        def read_loop
          buffer = +""
          loop do
            chunk = @read_io.readpartial(4096)
            buffer << chunk
            while (idx = buffer.index("\n"))
              line = buffer.slice!(0, idx + 1).chomp
              next if line.strip.empty?

              handle_line(line)
            end
          end
        rescue EOFError, IOError, Errno::EIO
          nil
        ensure
          signal_disconnect(nil)
        end

        def handle_line(line)
          message = JSON.parse(line)
        rescue JSON::ParserError => e
          signal_disconnect(e)
          return
        else
          dispatch_message(message)
        end

        def dispatch_message(message)
          if message["id"] && message["method"]
            handle_server_request(message)
            return
          end

          if message.key?("id")
            pending = @id_mutex.synchronize { @pending.delete(message["id"]) }
            return unless pending

            if message["error"]
              err_msg = message.dig("error", "message") || "RPC error"
              pending.push(StandardError.new("codex_appserver RPC error: #{err_msg}"))
              signal_disconnect(message["error"])
            else
              pending.push(message["result"] || {})
            end
            return
          end

          @notification_handler&.call(message) if message["method"]
        end

        def handle_server_request(message)
          result =
            begin
              @request_handler&.call(message["method"], message["params"] || {})
            rescue StandardError
              nil
            end

          if result.nil?
            write_line({
              jsonrpc: "2.0",
              id: message["id"],
              error: { code: -32601, message: "Unsupported server request: #{message['method']}" }
            })
          else
            write_line({
              jsonrpc: "2.0",
              id: message["id"],
              result: result
            })
          end
        end

        def signal_disconnect(error)
          return if @disconnect_signaled

          @disconnect_signaled = true
          @disconnect_handler&.call(error)
        end

        def process_alive?(pid)
          Process.kill(0, pid)
          true
        rescue Errno::ESRCH, Errno::EPERM
          false
        end

        def wait_for_process_exit(pid, timeout_seconds)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds.to_f
          loop do
            return true unless process_alive?(pid)

            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0

            sleep([0.05, remaining].min)
          end

          !process_alive?(pid)
        end
      end
    end
  end
end
