require "json"
require "net/http"
require "optparse"
require "shellwords"
require "stringio"
require "uri"

module Harnex
  class Sender
    DEFAULT_TIMEOUT = 120.0
    MIN_HTTP_TIMEOUT = 0.1
    POLL_INTERVAL = 0.5
    IDLE_FENCE_TIMEOUT = 30.0
    class TimeoutError < RuntimeError; end

    def self.build_parser(options, program_name = "harnex send")
      OptionParser.new do |opts|
        opts.banner = "Usage: #{program_name} --id ID [options] [text...]"
        opts.on("--id ID", "Target session ID") { |value| options[:id] = Harnex.normalize_id(value) }
        opts.on("--repo PATH", "Resolve the target using PATH's repo root") { |value| options[:repo_path] = value }
        opts.on("--cli CLI", "Filter by CLI type") { |value| options[:cli] = value }
        opts.on("--message TEXT", "Message text to inject instead of positional args") { |value| options[:message] = value }
        opts.on("--no-submit", "Inject text without pressing Enter") { options[:submit] = false }
        opts.on("--submit-only", "Press Enter without injecting text") do
          options[:submit_only] = true
          options[:submit] = true
        end
        opts.on("--force", "Send even if the agent is not at a prompt") { options[:force] = true }
        opts.on("--no-wait", "Return immediately after queueing (HTTP 202). Use for fire-and-forget or when polling delivery separately.") { options[:wait] = false }
        opts.on("--wait-for-idle", "After a successful send, wait for the agent to return to prompt") { options[:wait_for_idle] = true }
        opts.on("--wait-done", "After delivery, block until the turn it started or joined completes or fails (exit codes of wait --until done)") { options[:wait_done] = true }
        opts.on("--stall-after DUR", "With --wait-done: exit 4 when the turn shows no progress for DUR") do |value|
          options[:stall_after] = Harnex.parse_duration_seconds(value, option_name: "--stall-after")
        end
        opts.on("--relay", "Force relay header formatting") { options[:relay] = true }
        opts.on("--no-relay", "Disable automatic relay headers") { options[:relay] = false }
        opts.on("--port PORT", Integer, "Send directly to a specific port") { |value| options[:port] = value }
        opts.on("--token TOKEN", "Auth token for --port mode") { |value| options[:token] = value }
        opts.on("--host HOST", "Override the host when --port is used") { |value| options[:host] = value }
        opts.on("--timeout SECS", Float, "How long to wait for lookup, delivery, or idle wait (default: #{DEFAULT_TIMEOUT.to_i}; --wait-done is uncapped unless given)") do |value|
          options[:timeout] = value
          options[:timeout_explicit] = true
        end
        opts.on("--verbose", "Print lookup and delivery details to stderr") { options[:verbose] = true }
        opts.on("-h", "--help", "Show help") { options[:help] = true }
      end
    end

    def self.usage(program_name = "harnex send")
      <<~TEXT
        #{build_parser({}, program_name)}
        Common patterns:
          #{program_name} --id pi-i-42 --message "Read /tmp/task-impl-42.md" --wait-for-idle --timeout 900
          #{program_name} --id pi-i-42 --message "Continue with the current task." --force
          #{program_name} --id pi-i-42 --message "Continue the same task from where you stopped" --wait-done --timeout 540
          #{program_name} --id "$HARNEX_ID" --message "Worker finished; tests passed."

        Gotchas:
          --wait-for-idle is a turn fence, not proof that the whole task is done.
          Every delivery reports after_seq: `harnex wait --id ID --until done --after-seq N`
            waits for the turn that message started or joined, never an earlier result.
            --wait-done does both in one call; on timeout (124) resume with that wait.
          A busy Pi session takes the message at once as a follow-up (delivery:
            "follow_up"), delivered when its current turn ends; --force steers mid-turn.
          Other adapters queue until the agent is at a prompt. If it is not delivered
            within --timeout the message is withdrawn and send exits 124; one that
            expires in the inbox (--inbox-ttl) exits 1 with status "expired".
          Use --no-wait for fire-and-forget delivery only when another monitor owns completion.
          Long prompts are more reliable when written to a file and referenced by path.
          Messages between harnex sessions get relay headers unless --no-relay is used.
      TEXT
    end

    def initialize(argv)
      @options = {
        repo_path: Dir.pwd,
        id: nil,
        cli: nil,
        message: nil,
        submit: true,
        submit_only: false,
        relay: nil,
        force: false,
        wait: true,
        wait_for_idle: false,
        wait_done: false,
        port: nil,
        token: nil,
        host: DEFAULT_HOST,
        timeout: DEFAULT_TIMEOUT,
        timeout_explicit: false,
        verbose: false,
        help: false
      }
      @argv = argv.dup
    end

    def run
      parser.parse!(@argv)
      if @options[:help]
        puts parser
        return 0
      end

      raise "--id is required for harnex send" unless @options[:id]
      validate_modes!

      repo_root = Harnex.resolve_repo_root(@options[:repo_path])
      @command_started_at = monotonic_now
      deadline = @command_started_at + @options[:timeout]
      verbose("repo_root=#{repo_root}")
      verbose("id=#{@options[:id]}")
      verbose("cli=#{@options[:cli] || '(any)'}")

      registry = wait_for_registry(repo_root, deadline: deadline)
      case registry
      when :ambiguous
        raise ambiguous_session_message(repo_root)
      when :timeout
        puts JSON.generate(ok: false, id: @options[:id], status: "timeout", error: "lookup timed out after #{@options[:timeout]}s")
        return 124
      when :exited
        puts JSON.generate(ok: false, id: @options[:id], status: "exited",
                           error: "session #{@options[:id]} has exited; nothing to send to (start a new one with harnex run)")
        return 1
      end

      registry = direct_registry.merge(registry || {})
      verbose("target=http://#{registry.fetch('host')}:#{registry.fetch('port')}/send")

      text = resolve_text
      text = relay_text(text, registry)
      raise "text is required" if text.to_s.empty? && !@options[:submit_only]

      response = with_http_retry(deadline: deadline) do
        uri = URI("http://#{registry.fetch('host')}:#{registry.fetch('port')}/send")
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{registry['token']}" if registry["token"]
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(
          text: text,
          submit: @options[:submit],
          enter_only: @options[:submit_only],
          force: @options[:force],
          from: Harnex.sender_identity
        )

        Net::HTTP.start(
          uri.host,
          uri.port,
          open_timeout: http_timeout(deadline),
          read_timeout: http_timeout(deadline)
        ) { |http| http.request(request) }
      end

      result = nil
      exit_code = nil

      if response.code == "202" && @options[:wait]
        parsed = parse_json_body(response.body)
        message_id = parsed["message_id"]
        if message_id
          verbose("queued message_id=#{message_id}")
          result = poll_delivery(registry, message_id, deadline: deadline)
          exit_code =
            case result["status"]
            when "timeout" then 124
            when "delivered" then 0
            else 1
            end
        end
      end

      unless result
        result = parse_json_body(response.body)
        exit_code = response.is_a?(Net::HTTPSuccess) ? 0 : 1
      end

      if exit_code == 0 && @options[:wait_for_idle]
        result = wait_for_idle_state(registry, deadline)
        exit_code = result["ok"] ? 0 : (result["state"] == "exited" ? 1 : 124)
      end

      return wait_for_turn_done(result, deadline) if exit_code == 0 && @options[:wait_done]

      puts JSON.generate(result)
      exit_code
    rescue TimeoutError => e
      puts JSON.generate(ok: false, id: @options[:id], status: "timeout", error: e.message)
      124
    end

    private

    def resolve_text
      return "" if @options[:submit_only]
      return @options[:message] if @options[:message]
      return @argv.join(" ") unless @argv.empty?
      return STDIN.read unless STDIN.tty?

      raise "harnex send: no message provided (use --message, positional args, or pipe)"
    end

    def poll_delivery(registry, message_id, deadline:)
      base = "http://#{registry.fetch('host')}:#{registry.fetch('port')}"
      uri = URI("#{base}/messages/#{message_id}")

      loop do
        break if deadline_reached?(deadline)

        parsed = fetch_message(registry, uri, deadline)
        status = parsed["status"]

        return parsed if %w[delivered failed].include?(status)
        # #79: an expired or dropped message is lost; say so at once instead
        # of polling until our own deadline.
        return parsed.merge("ok" => false, "error" => parsed["error"] || "message #{status} undelivered") if %w[expired dropped].include?(status)
        break if deadline_reached?(deadline)

        verbose("delivery status=#{status || 'unknown'}")
        sleep 0.25
      rescue StandardError
        break if deadline_reached?(deadline)

        sleep 0.25
      end
      withdraw_undelivered(registry, message_id)
    end

    def fetch_message(registry, uri, deadline)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{registry['token']}" if registry["token"]
      response = Net::HTTP.start(
        uri.host,
        uri.port,
        open_timeout: http_timeout(deadline, cap: 1.0),
        read_timeout: http_timeout(deadline, cap: 2.0)
      ) { |http| http.request(request) }
      parse_json_body(response.body)
    end

    # The sender gave up: take the message back so it cannot land later,
    # unannounced, in a turn the caller no longer expects (#79).
    def withdraw_undelivered(registry, message_id)
      timeout = { "ok" => false, "status" => "timeout", "message_id" => message_id, "error" => timeout_message("delivery") }
      base = "http://#{registry.fetch('host')}:#{registry.fetch('port')}"
      request = Net::HTTP::Delete.new(URI("#{base}/inbox/#{message_id}"))
      request["Authorization"] = "Bearer #{registry['token']}" if registry["token"]
      response = Net::HTTP.start(registry.fetch("host"), registry.fetch("port"), open_timeout: 1, read_timeout: 2) do |http|
        http.request(request)
      end
      if response.is_a?(Net::HTTPSuccess)
        return timeout.merge(
          "withdrawn" => true,
          "error" => "not delivered within #{@options[:timeout]}s: agent busy; message withdrawn " \
                     "(use --force to inject mid-turn, or a longer --timeout)"
        )
      end

      # Not queued any more: it may have been delivered at the last moment.
      parsed = fetch_message(registry, URI("#{base}/messages/#{message_id}"), monotonic_now + 2.0)
      %w[delivered failed expired].include?(parsed["status"]) ? parsed : timeout
    rescue StandardError
      timeout
    end

    # #81: block until the turn this message started (or joined) settles.
    # The payload keeps after_seq so a caller whose --timeout ran out can
    # resume with `harnex wait --until done --after-seq N`.
    def wait_for_turn_done(result, deadline)
      after_seq = result["after_seq"]
      unless after_seq.is_a?(Integer)
        puts JSON.generate(result.merge("ok" => false, "error" => "the session reported no after_seq; use harnex wait --until done"))
        return 1
      end

      argv = ["--id", @options[:id], "--repo", @options[:repo_path], "--until", "done", "--after-seq", after_seq.to_s]
      argv += ["--stall-after", @options[:stall_after].to_s] if @options[:stall_after]
      if @options[:timeout_explicit]
        remaining = deadline - monotonic_now
        unless remaining.positive?
          puts JSON.generate(result.merge("ok" => false, "wait_result" => "timeout", "error" => timeout_message("turn wait")))
          return 124
        end
        argv += ["--timeout", remaining.round(3).to_s]
      end
      out = StringIO.new
      exit_code = Waiter.new(argv, out: out, err: $stderr).run
      turn = parse_json_body(out.string.lines.last.to_s)
      # `status` is the turn's verdict; the delivery's own status moves to
      # delivery_status so a timed-out wait never reads as "delivered".
      payload = result.merge("ok" => turn["ok"] == true, "status" => turn["wait_result"] || "unknown",
                             "delivery_status" => result["status"], "wait_result" => turn["wait_result"],
                             "turn_result" => turn)
      if exit_code == Waiter::DONE_EXIT_TIMEOUT
        payload["resume"] = "#{Harnex.cli_command} wait --id #{@options[:id]} --repo #{Shellwords.escape(@options[:repo_path])} " \
                            "--until done --after-seq #{after_seq} --timeout 9m"
      end
      puts JSON.generate(payload)
      exit_code
    end

    def wait_for_idle_state(registry, deadline)
      host = registry.fetch("host")
      port = registry.fetch("port")
      token = registry["token"]
      last_state = "prompt"
      fence_deadline = [monotonic_now + IDLE_FENCE_TIMEOUT, deadline].min

      loop do
        return wait_for_idle_timeout(last_state) if deadline_reached?(deadline)

        state = fetch_agent_state(host, port, token)
        return wait_for_idle_exited if state.nil?

        last_state = state
        break if state != "prompt"
        return wait_for_idle_success("prompt") if monotonic_now >= fence_deadline

        sleep POLL_INTERVAL
      end

      loop do
        return wait_for_idle_timeout(last_state) if deadline_reached?(deadline)

        state = fetch_agent_state(host, port, token)
        return wait_for_idle_exited if state.nil?

        last_state = state
        return wait_for_idle_success(state) if state == "prompt"

        sleep POLL_INTERVAL
      end
    end

    def relay_text(text, registry)
      return text if text.to_s.empty?
      return text unless relay_enabled_for?(registry)
      return text if text.lstrip.start_with?("[harnex relay ")

      context = Harnex.current_session_context
      Harnex.format_relay_message(
        text,
        from: context.fetch(:cli),
        id: context.fetch(:id)
      )
    end

    def relay_enabled_for?(registry)
      return false if @options[:submit_only]
      return false if @options[:relay] == false

      context = Harnex.current_session_context
      return false unless context
      return true if @options[:relay] == true

      target_session_id = registry["session_id"].to_s
      return false if target_session_id.empty?

      target_session_id != context.fetch(:session_id)
    end

    def verbose(message)
      return unless @options[:verbose]

      warn("[harnex send] #{message}")
    end

    # A session that already exited fails fast (after a short grace for an
    # id being relaunched) instead of spending the whole --timeout on lookup.
    EXITED_GRACE_S = 2.0

    def wait_for_registry(repo_root, deadline:)
      return nil if @options[:port]

      started = monotonic_now
      loop do
        registry = resolve_registry(repo_root)
        return registry unless registry == :retry
        return :timeout if deadline_reached?(deadline)
        return :exited if @options[:id] && monotonic_now - started >= EXITED_GRACE_S &&
                          File.exist?(Harnex.exit_status_path(repo_root, @options[:id]))

        sleep 0.1
      end
    end

    def resolve_registry(repo_root)
      sessions = Harnex.active_sessions(repo_root, id: @options[:id], cli: @options[:cli])
      return :retry if sessions.empty?
      return sessions.first if sessions.length == 1

      :ambiguous
    end

    def direct_registry
      return {} unless @options[:port]

      registry = {
        "host" => @options[:host],
        "port" => @options[:port]
      }
      registry["token"] = @options[:token] if @options[:token]
      registry
    end

    def missing_session_message(repo_root)
      base = "no active harnex session found for #{repo_root}"
      filters = []
      filters << "id: #{@options[:id]}" if @options[:id]
      filters << "cli: #{@options[:cli]}" if @options[:cli]
      return "#{base} (#{filters.join(', ')})" unless filters.empty?

      available = Harnex.active_sessions(repo_root).map { |session| "#{session['id']}(#{Harnex.session_cli(session)})" }.uniq.sort
      suffix = available.empty? ? "" : " | active: #{available.join(', ')}"
      "#{base}#{suffix}"
    end

    def ambiguous_session_message(repo_root)
      available = Harnex.active_sessions(repo_root, id: @options[:id], cli: @options[:cli])
      detail = available.map { |session| "#{session['id']}(#{Harnex.session_cli(session)})" }.join(", ")
      filters = []
      filters << "id #{@options[:id].inspect}" if @options[:id]
      filters << "cli #{@options[:cli].inspect}" if @options[:cli]
      scope = filters.empty? ? repo_root : "#{repo_root} with #{filters.join(' and ')}"
      "multiple active harnex sessions found for #{scope}; use --id, --cli, or `harnex status` | active: #{detail}"
    end

    def with_http_retry(deadline:)
      loop do
        raise TimeoutError, timeout_message("request") if deadline_reached?(deadline)

        return yield
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, EOFError, Net::ReadTimeout, Net::OpenTimeout => e
        raise TimeoutError, timeout_message("request") if deadline_reached?(deadline)

        verbose("retrying after #{e.class}")
        sleep 0.1
      end
    end

    def fetch_agent_state(host, port, token)
      uri = URI("http://#{host}:#{port}/status")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{token}" if token

      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 1) do |http|
        http.request(request)
      end

      return nil unless response.is_a?(Net::HTTPSuccess)

      data = JSON.parse(response.body)
      data["agent_state"]
    rescue StandardError
      nil
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def deadline_reached?(deadline)
      monotonic_now >= deadline
    end

    def http_timeout(deadline, cap: nil)
      remaining = deadline - monotonic_now
      remaining = [remaining, MIN_HTTP_TIMEOUT].max
      cap ? [remaining, cap].min : remaining
    end

    def timeout_message(phase)
      "#{phase} timed out after #{@options[:timeout]}s"
    end

    def waited_seconds
      return 0.0 unless @command_started_at

      (monotonic_now - @command_started_at).round(1)
    end

    def wait_for_idle_success(state)
      {
        "ok" => true,
        "id" => @options[:id],
        "state" => state,
        "waited_seconds" => waited_seconds
      }
    end

    def wait_for_idle_timeout(state)
      {
        "ok" => false,
        "id" => @options[:id],
        "state" => state || "unknown",
        "error" => "timeout",
        "waited_seconds" => waited_seconds
      }
    end

    def wait_for_idle_exited
      {
        "ok" => false,
        "id" => @options[:id],
        "state" => "exited",
        "waited_seconds" => waited_seconds
      }
    end

    def parse_json_body(body)
      JSON.parse(body.to_s.empty? ? "{}" : body.to_s)
    rescue JSON::ParserError
      { "ok" => false, "error" => "invalid json response", "raw_body" => body.to_s }
    end

    def validate_modes!
      raise "--submit-only cannot be combined with --no-submit" if @options[:submit_only] && !@options[:submit]
      raise "--wait-done cannot be combined with --no-wait" if @options[:wait_done] && !@options[:wait]
      raise "--wait-done cannot be combined with --wait-for-idle" if @options[:wait_done] && @options[:wait_for_idle]
      raise "--stall-after requires --wait-done" if @options[:stall_after] && !@options[:wait_done]

      return unless @options[:submit_only]
      return if @options[:message].nil? && @argv.empty?

      raise "--submit-only does not accept message text"
    end

    def parser
      @parser ||= self.class.build_parser(@options)
    end
  end
end
