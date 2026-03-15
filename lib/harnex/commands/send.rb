require "json"
require "net/http"
require "optparse"
require "uri"

module Harnex
  class Sender
    DEFAULT_TIMEOUT = 120.0
    MIN_HTTP_TIMEOUT = 0.1
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
        opts.on("--relay", "Force relay header formatting") { options[:relay] = true }
        opts.on("--no-relay", "Disable automatic relay headers") { options[:relay] = false }
        opts.on("--port PORT", Integer, "Send directly to a specific port") { |value| options[:port] = value }
        opts.on("--token TOKEN", "Auth token for --port mode") { |value| options[:token] = value }
        opts.on("--host HOST", "Override the host when --port is used") { |value| options[:host] = value }
        opts.on("--timeout SECS", Float, "How long to wait for lookup or delivery (default: #{DEFAULT_TIMEOUT.to_i})") { |value| options[:timeout] = value }
        opts.on("--verbose", "Print lookup and delivery details to stderr") { options[:verbose] = true }
        opts.on("-h", "--help", "Show help") { options[:help] = true }
      end
    end

    def self.usage(program_name = "harnex send")
      build_parser({}, program_name).to_s
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
        port: nil,
        token: nil,
        host: DEFAULT_HOST,
        timeout: DEFAULT_TIMEOUT,
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
      deadline = monotonic_now + @options[:timeout]
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
          force: @options[:force]
        )

        Net::HTTP.start(
          uri.host,
          uri.port,
          open_timeout: http_timeout(deadline),
          read_timeout: http_timeout(deadline)
        ) { |http| http.request(request) }
      end

      if response.code == "202" && @options[:wait]
        parsed = parse_json_body(response.body)
        message_id = parsed["message_id"]
        if message_id
          verbose("queued message_id=#{message_id}")
          result = poll_delivery(registry, message_id, deadline: deadline)
          puts JSON.generate(result)
          return 124 if result["status"] == "timeout"

          return result["status"] == "delivered" ? 0 : 1
        end
      end

      parsed = parse_json_body(response.body)
      puts JSON.generate(parsed)
      response.is_a?(Net::HTTPSuccess) ? 0 : 1
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
        return({ "ok" => false, "status" => "timeout", "error" => timeout_message("delivery") }) if deadline_reached?(deadline)

        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{registry['token']}" if registry["token"]
        response = Net::HTTP.start(
          uri.host,
          uri.port,
          open_timeout: http_timeout(deadline, cap: 1.0),
          read_timeout: http_timeout(deadline, cap: 2.0)
        ) { |http| http.request(request) }
        parsed = parse_json_body(response.body)
        status = parsed["status"]

        return parsed if %w[delivered failed].include?(status)
        return parsed.merge("status" => "timeout", "error" => timeout_message("delivery")) if deadline_reached?(deadline)

        verbose("delivery status=#{status || 'unknown'}")
        sleep 0.25
      rescue StandardError => e
        return({ "ok" => false, "status" => "timeout", "error" => timeout_message("delivery") }) if deadline_reached?(deadline)

        sleep 0.25
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

    def wait_for_registry(repo_root, deadline:)
      return nil if @options[:port]

      loop do
        registry = resolve_registry(repo_root)
        return registry unless registry == :retry
        return :timeout if deadline_reached?(deadline)

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

    def parse_json_body(body)
      JSON.parse(body.to_s.empty? ? "{}" : body.to_s)
    rescue JSON::ParserError
      { "ok" => false, "error" => "invalid json response", "raw_body" => body.to_s }
    end

    def validate_modes!
      raise "--submit-only cannot be combined with --no-submit" if @options[:submit_only] && !@options[:submit]

      return unless @options[:submit_only]
      return if @options[:message].nil? && @argv.empty?

      raise "--submit-only does not accept message text"
    end

    def parser
      @parser ||= self.class.build_parser(@options)
    end
  end
end
