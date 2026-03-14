require "json"
require "net/http"
require "optparse"
require "uri"

module Harnex
  class Sender
    def self.build_parser(options, program_name = "harnex send")
      OptionParser.new do |opts|
        opts.banner = "Usage: #{program_name} [options] [text...]"
        opts.on("--repo PATH", "Resolve the active session using PATH's repo root") { |value| options[:repo_path] = Harnex.ensure_option_value!("--repo", value) }
        opts.on("--id ID", "Target a session by ID") { |value| options[:id] = Harnex.normalize_id(Harnex.ensure_option_value!("--id", value)) }
        opts.on("--label ID", "Alias for --id (deprecated)") { |value| options[:id] = Harnex.normalize_id(Harnex.ensure_option_value!("--label", value)) }
        opts.on("--cli CLI", Adapters.supported, "Filter by CLI type (#{Adapters.supported.join(', ')})") { |value| options[:cli] = value }
        opts.on("--message TEXT", "Message text to inject without using positional args") { |value| options[:message] = Harnex.ensure_option_value!("--message", value) }
        opts.on("--port PORT", Integer, "Send directly to a specific port") { |value| options[:port] = value }
        opts.on("--token TOKEN", "Auth token for --port mode (from session registry)") { |value| options[:token] = Harnex.ensure_option_value!("--token", value) }
        opts.on("--host HOST", "Override the host when --port is used") { |value| options[:host] = Harnex.ensure_option_value!("--host", value) }
        opts.on("--wait SECONDS", Float, "How long to wait for the target session to appear/respond") { |value| options[:wait_seconds] = value }
        opts.on("--status", "Print session status instead of sending text") { options[:status] = true }
        opts.on("--enter", "Send only Enter to submit the current prompt") do
          options[:enter_only] = true
          options[:submit] = true
        end
        opts.on("--no-submit", "Inject text without pressing Enter") { options[:submit] = false }
        opts.on("--relay", "Force relay header formatting for sends from a wrapped session") { options[:relay] = true }
        opts.on("--no-relay", "Disable automatic relay header formatting") { options[:relay] = false }
        opts.on("--force", "Send input even if the adapter says the UI is not at a prompt") { options[:force] = true }
        opts.on("--async", "Return immediately with message_id when queued (don't wait for delivery)") { options[:async] = true }
        opts.on("--debug", "Print repo/session lookup details to stderr") { options[:debug] = true }
        opts.on("-h", "--help", "Show help") { options[:help] = true }
      end
    end

    def self.usage(program_name = "harnex send")
      build_parser({}, program_name).to_s
    end

    def initialize(argv)
      @options = {
        repo_path: Dir.pwd,
        id: Harnex.configured_id,
        cli: nil,
        message: nil,
        submit: true,
        enter_only: false,
        relay: nil,
        force: false,
        async: false,
        status: false,
        port: nil,
        token: nil,
        host: DEFAULT_HOST,
        wait_seconds: Float(Harnex.env_value("HARNEX_SEND_WAIT", legacy: "CXW_SEND_WAIT", default: "30.0")),
        debug: false,
        help: false
      }
      @argv = argv
    end

    def run
      parser.parse!(@argv)
      if @options[:help]
        puts parser
        return 0
      end

      repo_root = Harnex.resolve_repo_root(@options[:repo_path])
      debug("repo_root=#{repo_root}")
      debug("id=#{@options[:id] || '(auto)'}")
      debug("cli=#{@options[:cli] || '(any)'}")
      registry = wait_for_registry(repo_root)

      if @options[:port]
        registry ||= {}
        registry["host"] ||= @options[:host]
        registry["port"] = @options[:port]
        registry["token"] = @options[:token] if @options[:token]
      end

      case registry
      when :ambiguous
        raise ambiguous_session_message(repo_root)
      when nil
        raise missing_session_message(repo_root)
      end

      uri = URI("http://#{registry.fetch('host', @options[:host])}:#{registry.fetch('port')}#{@options[:status] ? '/status' : '/send'}")
      debug("target=#{uri}")
      text = nil
      unless @options[:status]
        text = resolve_text
        text = relay_text(text, registry)
        raise "text is required" if text.to_s.empty? && !@options[:enter_only]
        debug("payload_bytes=#{text.bytesize} submit=#{@options[:submit]} enter_only=#{@options[:enter_only]} relay=#{relay_enabled_for?(registry)} force=#{@options[:force]}")
      end

      response = with_http_retry do
        request = @options[:status] ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{registry['token']}" if registry["token"]

        unless @options[:status]
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(
            text: text,
            submit: @options[:submit],
            enter_only: @options[:enter_only],
            force: @options[:force]
          )
        end

        Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
      end

      if response.code == "202" && !@options[:async]
        parsed = JSON.parse(response.body)
        message_id = parsed["message_id"]
        if message_id
          debug("queued message_id=#{message_id}, polling for delivery...")
          result = poll_delivery(registry, message_id)
          puts JSON.generate(result)
          return result["status"] == "delivered" ? 0 : 1
        end
      end

      puts response.body
      response.is_a?(Net::HTTPSuccess) ? 0 : 1
    end

    private

    def resolve_text
      return "" if @options[:enter_only]

      @options[:message] || (@argv.empty? ? STDIN.read : @argv.join(" "))
    end

    def poll_delivery(registry, message_id)
      base = "http://#{registry.fetch('host', @options[:host])}:#{registry.fetch('port')}"
      uri = URI("#{base}/messages/#{message_id}")
      deadline = Time.now + @options[:wait_seconds]
      dots = 0

      loop do
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{registry['token']}" if registry["token"]
        response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 2) { |http| http.request(request) }
        parsed = JSON.parse(response.body)

        case parsed["status"]
        when "delivered", "failed"
          warn("") if dots.positive?
          return parsed
        end

        if Time.now >= deadline
          warn("") if dots.positive?
          return parsed.merge("error" => "poll timeout after #{@options[:wait_seconds]}s")
        end

        warn(".") if @options[:debug] || dots.zero?
        dots += 1
        sleep 0.25
      rescue StandardError => e
        if Time.now >= deadline
          return { "status" => "unknown", "error" => e.message }
        end
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
      return false if @options[:enter_only] || @options[:status]
      return false if @options[:relay] == false

      context = Harnex.current_session_context
      return false unless context
      return true if @options[:relay] == true

      target_session_id = registry["session_id"].to_s
      return false if target_session_id.empty?

      target_session_id != context.fetch(:session_id)
    end

    def debug(message)
      return unless @options[:debug]

      warn("[harnex send] #{message}")
    end

    def wait_for_registry(repo_root)
      return nil if @options[:port]

      deadline = Time.now + @options[:wait_seconds]
      loop do
        registry = resolve_registry(repo_root)
        return registry unless registry == :retry
        return nil if Time.now >= deadline

        sleep 0.1
      end
    end

    def resolve_registry(repo_root)
      sessions =
        Harnex.active_sessions(
          repo_root,
          id: @options[:id],
          cli: @options[:cli]
        )

      return :retry if sessions.empty?
      return sessions.first if sessions.length == 1

      :ambiguous
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

    def with_http_retry
      deadline = Time.now + @options[:wait_seconds]
      loop do
        return yield
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, EOFError
        raise if Time.now >= deadline
        sleep 0.1
      rescue Net::ReadTimeout, Net::OpenTimeout
        raise if Time.now >= deadline
        sleep 0.1
      end
    end

    def parser
      @parser ||= self.class.build_parser(@options)
    end
  end
end
