require "json"
require "open3"

module Harnex
  module Adapters
    # Pi RPC adapter — JSONL command/event protocol over stdio.
    #
    # Protocol docs: `pi --mode rpc` (strict LF-delimited JSON lines).
    class Pi < Base
      STOP_TERM_GRACE_SECONDS = 0.5
      STOP_KILL_GRACE_SECONDS = 1.0
      DIALOG_UI_METHODS = %w[select confirm input editor].freeze

      attr_reader :initial_prompt, :last_completed_at

      def initialize(extra_args = [])
        super("pi", extra_args)
        @initial_prompt = extract_initial_prompt(extra_args)
        @notification_handler = nil
        @disconnect_handler = nil
        @read_io = nil
        @write_io = nil
        @pid = nil
        @reader_thread = nil
        @closed = false
        @disconnect_signaled = false
        @state = :disconnected
        @next_id = 1
        @pending = {}
        @id_mutex = Mutex.new
        @write_mutex = Mutex.new
        @summary_mutex = Mutex.new
        @session_summary = {}
        @context_telemetry = ContextTelemetry.new(
          status: "observed",
          source: context_telemetry_source
        )
        @model = nil
        @provider = nil
        @session_stats_requested = false
        @last_completed_at = nil
      end

      def transport
        :stdio_jsonl_rpc
      end

      def provider
        @provider
      end

      def current_model
        @model
      end

      def usage_telemetry_supported?
        true
      end

      def context_telemetry_supported?
        true
      end

      def context_telemetry_source
        "pi_get_session_stats"
      end

      def base_command
        ["pi", "--mode", "rpc"]
      end

      def build_command
        base_command + cli_extra_args
      end

      def describe
        {
          transport: transport,
          protocol: "jsonl",
          events: %w[
            agent_start agent_end turn_start turn_end message_start message_update message_end
            tool_execution_start tool_execution_update tool_execution_end queue_update
            compaction_start compaction_end auto_retry_start auto_retry_end extension_error
            extension_ui_request
          ]
        }
      end

      def state
        @state
      end

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

        raise ArgumentError, "Pi RPC cannot stage input without submitting it" unless submit || enter_only
        raise ArgumentError, "Pi RPC does not support submit-only input" if enter_only

        {
          dispatch: { prompt: text.to_s },
          input_state: state,
          force: force
        }
      end

      def inject_exit(_writer, **_kwargs)
        nil
      end

      def on_notification(&block)
        @notification_handler = block
      end

      def on_disconnect(&block)
        @disconnect_handler = block
      end

      def start_rpc(env: nil, cwd: nil, read_io: nil, write_io: nil, pid: nil)
        if read_io && write_io
          @read_io = read_io
          @write_io = write_io
          @pid = pid
        else
          @pid, @write_io, @read_io = spawn_subprocess(env, cwd)
        end

        @closed = false
        @disconnect_signaled = false
        @state = :prompt
        @reader_thread = Thread.new { read_loop }
        request_state_async
        self
      end

      def dispatch(prompt:, model: nil, effort: nil)
        ensure_open!

        payload = { "type" => "prompt", "message" => prompt.to_s }
        payload["model"] = model if model
        payload["thinkingLevel"] = effort if effort

        request(payload)
        @state = :busy
        nil
      end

      def interrupt(turn_id: nil)
        ensure_open!
        request("type" => "abort")
      rescue StandardError
        nil
      end

      def request_session_stats_async
        return if @closed

        should_request = @summary_mutex.synchronize do
          next false if @session_stats_requested

          @session_stats_requested = true
        end
        return unless should_request

        write_line("type" => "get_session_stats")
      rescue StandardError
        clear_session_stats_request
        nil
      end

      def respond_extension_ui_cancel(request_id:, method:)
        return false unless DIALOG_UI_METHODS.include?(method.to_s)

        write_line(
          "type" => "extension_ui_response",
          "id" => request_id,
          "cancelled" => true
        )
        true
      rescue StandardError
        false
      end

      def collect_session_summary
        attempt_live_summary_refresh if connected?

        @summary_mutex.synchronize do
          {
            input_tokens: @session_summary[:input_tokens],
            output_tokens: @session_summary[:output_tokens],
            reasoning_tokens: nil,
            cached_tokens: @session_summary[:cached_tokens],
            total_tokens: @session_summary[:total_tokens],
            agent_session_id: @session_summary[:agent_session_id],
            tool_calls: @session_summary[:tool_calls],
            cost_usd: @session_summary[:cost_usd],
            cost_source: @session_summary[:cost_source],
            model: @session_summary[:model],
            agent_provider: @session_summary[:agent_provider],
            context: @context_telemetry.snapshot
          }
        end
      end

      def close
        return if @closed

        @closed = true
        fail_pending_requests(StandardError.new("pi rpc client closed"))

        begin
          @write_io.close unless @write_io&.closed?
        rescue IOError
          nil
        end

        @reader_thread&.join(2)
      ensure
        terminate_subprocess(
          term_grace_seconds: STOP_TERM_GRACE_SECONDS,
          kill_grace_seconds: STOP_KILL_GRACE_SECONDS
        )
      end

      def terminate_subprocess(term_grace_seconds: STOP_TERM_GRACE_SECONDS, kill_grace_seconds: STOP_KILL_GRACE_SECONDS)
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

      def pid
        @pid
      end

      private

      def request(payload)
        raise "pi rpc client is closed" if @closed

        queue = Queue.new
        id = @id_mutex.synchronize do
          assigned = @next_id
          @next_id += 1
          @pending[assigned] = queue
          assigned
        end

        write_line(payload.merge("id" => id))
        response = queue.pop
        raise response if response.is_a?(Exception)

        unless response["success"]
          raise "pi rpc #{response["command"] || payload["type"]} failed: #{response["error"] || "unknown error"}"
        end

        handle_response_data(response)
        response["data"] || {}
      end

      def request_state_async
        write_line("type" => "get_state")
      rescue StandardError
        nil
      end

      def attempt_live_summary_refresh
        request("type" => "get_session_stats")
      rescue StandardError
        nil
      end

      def read_loop
        buffer = +""
        loop do
          chunk = @read_io.readpartial(4096)
          buffer << chunk

          while (idx = buffer.index("\n"))
            line = buffer.slice!(0, idx + 1)
            line = line.chomp("\n")
            line = line.chomp("\r")
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
        handle_message(message)
      rescue JSON::ParserError => e
        signal_disconnect(e)
      end

      def handle_message(message)
        if message["type"] == "response"
          handle_response(message)
        else
          handle_event(message)
        end
      end

      def handle_response(message)
        pending = nil
        if message.key?("id") && !message["id"].nil?
          pending = @id_mutex.synchronize { @pending.delete(message["id"]) }
        end

        if pending
          pending.push(message)
          return
        end

        handle_response_data(message)
      end

      def handle_response_data(message)
        return unless message["type"] == "response" && message["success"]

        case message["command"]
        when "get_state"
          absorb_state_data(message["data"])
        when "get_session_stats"
          absorb_session_stats(message["data"])
        end
      end

      def handle_event(message)
        case message["type"]
        when "agent_start", "turn_start"
          @state = :busy
        when "agent_end"
          @state = :prompt
          @last_completed_at = Time.now
          request_session_stats_async
        when "compaction_end"
          request_session_stats_async
        when "message_end"
          absorb_model_from_message(message["message"])
        end

        @notification_handler&.call(message)
      rescue StandardError
        nil
      end

      def absorb_state_data(data)
        return unless data.is_a?(Hash)

        @state = data["isStreaming"] ? :busy : :prompt
        @state = :busy if data["isCompacting"]
        @summary_mutex.synchronize do
          @session_summary[:agent_session_id] = data["sessionId"] if data["sessionId"]
        end
        absorb_model(data["model"])
      end

      def absorb_session_stats(data)
        return unless data.is_a?(Hash)

        tokens = data["tokens"] || {}
        context_usage = data["contextUsage"]
        context_usage = {} unless context_usage.is_a?(Hash)
        @summary_mutex.synchronize do
          @session_summary[:input_tokens] = numeric_or_nil(tokens["input"])
          @session_summary[:output_tokens] = numeric_or_nil(tokens["output"])
          @session_summary[:cached_tokens] = numeric_or_nil(tokens["cacheRead"])
          @session_summary[:total_tokens] = numeric_or_nil(tokens["total"])
          @session_summary[:tool_calls] = numeric_or_nil(data["toolCalls"])
          @session_summary[:cost_usd] = float_or_nil(data["cost"])
          @session_summary[:cost_source] = "provider_reported" unless @session_summary[:cost_usd].nil?
          @session_summary[:agent_session_id] = data["sessionId"] if data["sessionId"]
          @session_summary[:model] = @model if @model
          @session_summary[:agent_provider] = @provider if @provider
          @context_telemetry.record(
            tokens: context_usage["tokens"],
            window_tokens: context_usage["contextWindow"],
            percent: context_usage["percent"]
          )
        end
      ensure
        clear_session_stats_request
      end

      def clear_session_stats_request
        @summary_mutex.synchronize { @session_stats_requested = false }
      rescue StandardError
        @session_stats_requested = false
      end

      def absorb_model_from_message(message)
        return unless message.is_a?(Hash)

        absorb_model({
          "provider" => message["provider"],
          "id" => message["model"]
        })
      end

      def absorb_model(model)
        case model
        when Hash
          model_id = model["id"]
          provider = model["provider"]
          @model = model_id if model_id.is_a?(String) && !model_id.empty?
          @provider = provider if provider.is_a?(String) && !provider.empty?
          if @provider.nil? && @model&.include?("/")
            @provider = @model.split("/", 2).first
          end
        when String
          return if model.empty?

          @model = model
          @provider = model.split("/", 2).first if model.include?("/")
        end
      end

      def numeric_or_nil(value)
        return nil if value.nil?

        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end

      def float_or_nil(value)
        return nil if value.nil?

        Float(value)
      rescue ArgumentError, TypeError
        nil
      end

      def write_line(payload)
        raise "pi rpc client is closed" if @closed

        @write_mutex.synchronize do
          @write_io.write(JSON.generate(payload))
          @write_io.write("\n")
          @write_io.flush
        end
      rescue Errno::EPIPE, IOError => e
        signal_disconnect(e)
        raise
      end

      def ensure_open!
        raise "pi rpc client not started" unless @read_io && @write_io
        raise "pi rpc disconnected" if @state == :disconnected
      end

      def connected?
        @read_io && @write_io && !@closed && @state != :disconnected
      end

      def fail_pending_requests(error)
        @id_mutex.synchronize do
          @pending.each_value { |queue| queue.push(error) }
          @pending.clear
        end
      end

      def signal_disconnect(error)
        return if @disconnect_signaled

        @disconnect_signaled = true
        @state = :disconnected
        fail_pending_requests(
          error.is_a?(Exception) ? error : StandardError.new("pi rpc disconnected")
        )
        @disconnect_handler&.call(error)
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
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

      def extract_initial_prompt(extra_args)
        return nil unless extra_args.is_a?(Array)

        prefixed = extra_args.find { |a| a.is_a?(String) && a.start_with?("[harnex session id=") }
        return prefixed if prefixed && !prefixed.empty?

        nil
      end

      def cli_extra_args
        @extra_args.reject { |a| a.is_a?(String) && a.start_with?("[harnex session id=") }
      end

      def spawn_subprocess(env, cwd)
        spawn_env = env || {}
        opts = {}
        opts[:chdir] = cwd if cwd
        stdin_io, stdout_io, _stderr_io, wait_thr = Open3.popen3(spawn_env, *build_command, **opts)
        [wait_thr.pid, stdin_io, stdout_io]
      end

      def blocked_message(state, enter_only:)
        return super if enter_only

        "Pi RPC is not at a prompt; wait and retry or use `harnex send --force` (state: #{state[:state]})"
      end
    end
  end
end
