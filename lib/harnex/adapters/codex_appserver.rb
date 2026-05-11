require "json"
require "open3"
require_relative "../codex/app_server/client"

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
        "item/commandExecution/requestApproval" => { decision: "accept" },
        "item/fileChange/requestApproval"       => { decision: "accept" }
      }.freeze

      attr_reader :thread_id, :current_turn_id, :last_completed_at, :initial_prompt

      def initialize(extra_args = [])
        super("codex", extra_args)
        reject_unsupported_codex_flags!
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

      def provider
        "openai"
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
          @client = Harnex::Codex::AppServer::Client.new(read_io: read_io, write_io: write_io, pid: pid)
        else
          spawn_pid, child_stdin, child_stdout = spawn_subprocess(env, cwd)
          @client = Harnex::Codex::AppServer::Client.new(read_io: child_stdout, write_io: child_stdin, pid: spawn_pid)
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
        @current_turn_id = result.dig("turn", "id")
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

        payload.dig("thread", "id")
      end

      def extract_initial_prompt(extra_args)
        return nil unless extra_args.is_a?(Array)

        prefixed = extra_args.find { |a| a.is_a?(String) && a.start_with?("[harnex session id=") }
        return prefixed if prefixed && !prefixed.empty?

        nil
      end

      # `codex app-server` does not implement `-m/--model`; passing it
      # causes the subprocess to exit at startup, surfacing only as a
      # null-message transport disconnect. Same flag still works on the
      # legacy PTY adapter (`harnex run codex --legacy-pty`).
      def reject_unsupported_codex_flags!
        bad = @extra_args.find do |a|
          s = a.to_s
          s == "-m" || s == "--model" || s.start_with?("--model=")
        end
        return unless bad

        raise ArgumentError,
          "-m/--model is not supported by `codex app-server`. Use `-c model=\"<name>\"` instead."
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
          @current_turn_id = params.dig("turn", "id")
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

    end
  end
end
