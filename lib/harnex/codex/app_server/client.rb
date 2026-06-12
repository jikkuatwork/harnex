require "json"
require "open3"

module Harnex
  module Codex
    module AppServer
      # Extracted from Adapters::CodexAppServer per issue #41 Slice A.
      # Pure move; behavior unchanged.
      class Client
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

        # Plan 30 Phase 2 — deployment-fallback subprocess restart.
        #
        # Spawns a `codex app-server` subprocess against a deployment_config
        # and wraps it in a fresh Client. Caller is responsible for wiring
        # handlers and running the JSON-RPC handshake — or use
        # `spawn_with_fallback` for the full restart-with-resume flow.
        def self.spawn(deployment_config:)
          command = deployment_config[:command] || deployment_config["command"]
          raise ArgumentError, "deployment_config requires :command" if command.nil? || Array(command).empty?

          env = deployment_config[:env] || deployment_config["env"] || {}
          cwd = deployment_config[:cwd] || deployment_config["cwd"]

          opts = {}
          opts[:chdir] = cwd if cwd

          stdin_io, stdout_io, _stderr_io, wait_thr = Open3.popen3(env, *Array(command), **opts)
          new(read_io: stdout_io, write_io: stdin_io, pid: wait_thr.pid)
        end

        # Plan 30 Phase 2 — full subprocess restart for deployment fallback.
        #
        # Spawns a new subprocess against the alternate deployment, wires
        # the supplied handlers, runs the initialize handshake, and resumes
        # the prior threadId. Returns the started Client.
        #
        # Handlers are installed *before* the reader thread starts so no
        # post-handshake notification is dropped.
        def self.spawn_with_fallback(prior_thread_id:, deployment_config:, handshake_params:,
                                      notification_handler: nil, request_handler: nil,
                                      disconnect_handler: nil)
          raise ArgumentError, "prior_thread_id required" if prior_thread_id.nil? || prior_thread_id.to_s.empty?

          client = spawn(deployment_config: deployment_config)
          client.on_notification(&notification_handler) if notification_handler
          client.on_request(&request_handler) if request_handler
          client.on_disconnect(&disconnect_handler) if disconnect_handler
          client.start

          begin
            client.request("initialize", handshake_params)
            client.notify("initialized", {})
            client.request("thread/resume", { threadId: prior_thread_id })
          rescue StandardError
            client.close
            raise
          end

          client
        end

        # Plan 30 Phase 2 — graceful stop ahead of a deployment switch.
        #
        # Best-effort: issues `turn/interrupt` for any in-flight turn
        # (bounded by interrupt_grace_seconds), drains pending RPC, and
        # tears the subprocess down with the same TERM/KILL escalation
        # used by `terminate_process`.
        def stop_for_fallback(in_flight_turn: nil,
                              term_grace_seconds: 0.5,
                              kill_grace_seconds: 1.0,
                              interrupt_grace_seconds: 0.5)
          if in_flight_turn && !@closed
            interrupt_thread = Thread.new do
              begin
                request("turn/interrupt", in_flight_turn)
              rescue StandardError
                nil
              end
            end
            interrupt_thread.kill unless interrupt_thread.join(interrupt_grace_seconds)
          end

          return true if @closed

          @closed = true

          fail_pending_requests(StandardError.new("codex_appserver client closed for fallback"))

          begin
            @write_io.close unless @write_io.closed?
          rescue IOError
            nil
          end

          terminated =
            if @pid
              terminate_process(
                term_grace_seconds: term_grace_seconds,
                kill_grace_seconds: kill_grace_seconds
              )
            else
              true
            end

          @reader_thread&.join(2)
          terminated
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
              pending.push(StandardError.new(err_msg))
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
          fail_pending_requests(error)
          @disconnect_handler&.call(error)
        end

        def fail_pending_requests(error)
          exception =
            if error.is_a?(Exception)
              error
            else
              message = error.is_a?(Hash) ? error["message"] : nil
              StandardError.new(message.to_s.empty? ? "codex_appserver disconnected" : message.to_s)
            end

          @id_mutex.synchronize do
            @pending.each_value { |queue| queue.push(exception) }
            @pending.clear
          end
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
