require "digest"
require "fileutils"
require "io/console"
require "json"
require "net/http"
require "open3"
require "optparse"
require "pty"
require "securerandom"
require "shellwords"
require "socket"
require "time"
require "uri"

module Harnex
  module_function

  def env_value(name, legacy: nil, default: nil)
    return ENV[name] if ENV.key?(name)
    return ENV[legacy] if legacy && ENV.key?(legacy)

    default
  end

  DEFAULT_HOST = env_value("HARNEX_HOST", legacy: "CXW_HOST", default: "127.0.0.1")
  DEFAULT_BASE_PORT = Integer(env_value("HARNEX_BASE_PORT", legacy: "CXW_BASE_PORT", default: "43000"))
  DEFAULT_PORT_SPAN = Integer(env_value("HARNEX_PORT_SPAN", legacy: "CXW_PORT_SPAN", default: "4000"))
  DEFAULT_LABEL = env_value("HARNEX_LABEL", legacy: "CXW_LABEL", default: "default")
  DEFAULT_COMMAND = env_value(
    "HARNEX_COMMAND",
    legacy: "CXW_COMMAND",
    default: "codex --dangerously-bypass-approvals-and-sandbox"
  )
  STATE_DIR = File.expand_path(env_value("HARNEX_STATE_DIR", legacy: "CXW_STATE_DIR", default: "~/.local/state/harnex"))
  SESSIONS_DIR = File.join(STATE_DIR, "sessions")

  def resolve_repo_root(path = Dir.pwd)
    output, status = Open3.capture2("git", "rev-parse", "--show-toplevel", chdir: path)
    status.success? ? output.strip : File.expand_path(path)
  rescue StandardError
    File.expand_path(path)
  end

  def repo_key(repo_root)
    Digest::SHA256.hexdigest(repo_root)[0, 16]
  end

  def normalize_label(label)
    value = label.to_s.strip
    raise "label is required" if value.empty?

    value
  end

  def label_key(label)
    normalize_label(label).downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
  end

  def suspicious_option_value?(value)
    value.to_s.start_with?("-")
  end

  def ensure_option_value!(option_name, value)
    return value unless suspicious_option_value?(value)

    raise ArgumentError, "#{option_name} requires a value"
  end

  def registry_path(repo_root, label = DEFAULT_LABEL)
    FileUtils.mkdir_p(SESSIONS_DIR)
    slug = label_key(label)
    slug = "default" if slug.empty?
    File.join(SESSIONS_DIR, "#{repo_key(repo_root)}--#{slug}.json")
  end

  def active_sessions(repo_root)
    pattern = File.join(SESSIONS_DIR, "#{repo_key(repo_root)}--*.json")
    Dir.glob(pattern).sort.filter_map do |path|
      data = JSON.parse(File.read(path))
      if data["pid"] && alive_pid?(data["pid"])
        data.merge("registry_path" => path)
      else
        FileUtils.rm_f(path)
        nil
      end
    rescue JSON::ParserError
      FileUtils.rm_f(path)
      nil
    end
  end

  def alive_pid?(pid)
    Process.kill(0, Integer(pid))
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def read_registry(repo_root, label = DEFAULT_LABEL)
    path = registry_path(repo_root, label)
    return nil unless File.exist?(path)

    data = JSON.parse(File.read(path))
    return data if data["pid"] && alive_pid?(data["pid"])

    FileUtils.rm_f(path)
    nil
  rescue JSON::ParserError
    nil
  end

  def write_registry(path, payload)
    tmp = "#{path}.tmp.#{Process.pid}"
    File.write(tmp, JSON.pretty_generate(payload))
    File.rename(tmp, path)
  end

  def allocate_port(repo_root, label, requested_port = nil, host: DEFAULT_HOST)
    if requested_port
      return requested_port if port_available?(host, requested_port)

      raise "port #{requested_port} is already in use on #{host}"
    end

    seed = Digest::SHA256.hexdigest("#{repo_root}\0#{normalize_label(label)}").to_i(16)
    offset = seed % DEFAULT_PORT_SPAN

    DEFAULT_PORT_SPAN.times do |index|
      port = DEFAULT_BASE_PORT + ((offset + index) % DEFAULT_PORT_SPAN)
      return port if port_available?(host, port)
    end

    raise "could not find a free port in #{DEFAULT_BASE_PORT}-#{DEFAULT_BASE_PORT + DEFAULT_PORT_SPAN - 1}"
  end

  def port_available?(host, port)
    server = TCPServer.new(host, port)
    server.close
    true
  rescue Errno::EADDRINUSE, Errno::EACCES
    false
  end

  def default_command(argv)
    Shellwords.split(DEFAULT_COMMAND) + argv
  end

  class Launcher
    def initialize(argv)
      @argv = argv.dup
      @options = {
        label: DEFAULT_LABEL,
        host: DEFAULT_HOST,
        port: (env_port = Harnex.env_value("HARNEX_PORT", legacy: "CXW_PORT")) && Integer(env_port),
        help: false
      }
    end

    def run
      child_args = extract_wrapper_options(@argv)
      if @options[:help]
        puts usage
        return 0
      end

      repo_root = Harnex.resolve_repo_root(infer_repo_path(child_args))
      session = Session.new(
        command: Harnex.default_command(child_args),
        repo_root: repo_root,
        host: @options[:host],
        port: @options[:port],
        label: @options[:label]
      )

      session.run
    end

    private

    def extract_wrapper_options(argv)
      forwarded = []
      index = 0

      while index < argv.length
        arg = argv[index]
        case arg
        when "--"
          forwarded.concat(argv[(index + 1)..] || [])
          break
        when "-h", "--help"
          @options[:help] = true
        when "--label"
          index += 1
          raise OptionParser::MissingArgument, "--label" if index >= argv.length
          @options[:label] = Harnex.normalize_label(Harnex.ensure_option_value!("--label", argv[index]))
        when /\A--label=(.+)\z/
          @options[:label] = Harnex.normalize_label(Regexp.last_match(1))
        when "--host"
          index += 1
          raise OptionParser::MissingArgument, "--host" if index >= argv.length
          @options[:host] = Harnex.ensure_option_value!("--host", argv[index])
        when /\A--host=(.+)\z/
          @options[:host] = Regexp.last_match(1)
        when "--port"
          index += 1
          raise OptionParser::MissingArgument, "--port" if index >= argv.length
          @options[:port] = Integer(Harnex.ensure_option_value!("--port", argv[index]))
        when /\A--port=(\d+)\z/
          @options[:port] = Integer(Regexp.last_match(1))
        else
          forwarded << arg
        end
        index += 1
      end

      forwarded
    end

    def usage
      <<~TEXT
        Usage: harnex [wrapper-options] [--] [wrapped-command-args...]

        Wrapper options:
          --label LABEL   Session label for this repo (default: #{DEFAULT_LABEL})
          --host HOST     Bind host for the local API (default: #{DEFAULT_HOST})
          --port PORT     Force a specific local API port
          -h, --help      Show this help

        All remaining args are forwarded to:
          #{DEFAULT_COMMAND}
      TEXT
    end

    def infer_repo_path(child_args)
      index = 0
      while index < child_args.length
        arg = child_args[index]
        case arg
        when "-C", "--cd"
          next_value = child_args[index + 1]
          return next_value if next_value
          break
        when /\A-C(.+)\z/
          return Regexp.last_match(1)
        end
        index += 1
      end

      Dir.pwd
    end
  end

  class Session
    attr_reader :repo_root, :host, :port, :session_id, :token, :command, :pid, :label

    def initialize(command:, repo_root:, host:, port: nil, label: DEFAULT_LABEL)
      @command = command
      @repo_root = repo_root
      @host = host
      @label = Harnex.normalize_label(label)
      @registry_path = Harnex.registry_path(repo_root, @label)
      @session_id = SecureRandom.hex(8)
      @token = SecureRandom.hex(16)
      @port = Harnex.allocate_port(repo_root, @label, port, host: host)
      @mutex = Mutex.new
      @injected_count = 0
      @last_injected_at = nil
      @started_at = Time.now
      @server = nil
      @reader = nil
      @writer = nil
      @pid = nil
    end

    def run
      @reader, @writer, @pid = PTY.spawn(*command)
      @writer.sync = true

      install_signal_handlers
      sync_window_size
      @server = ApiServer.new(self)
      @server.start
      persist_registry

      stdin_state = STDIN.tty? ? STDIN.raw! : nil
      input_thread = start_input_thread
      output_thread = start_output_thread

      _, status = Process.wait2(pid)
      @exit_code = status.exited? ? status.exitstatus : 128 + status.termsig

      output_thread.join(1)
      input_thread&.kill
      @exit_code
    ensure
      STDIN.cooked! if STDIN.tty? && stdin_state
      @server&.stop
      cleanup_registry
      @reader&.close unless @reader&.closed?
      @writer&.close unless @writer&.closed?
    end

    def status_payload
      {
        ok: true,
        session_id: session_id,
        repo_root: repo_root,
        repo_key: Harnex.repo_key(repo_root),
        label: label,
        pid: pid,
        host: host,
        port: port,
        command: command,
        started_at: @started_at.iso8601,
        last_injected_at: @last_injected_at&.iso8601,
        injected_count: @injected_count
      }
    end

    def auth_ok?(header)
      header == "Bearer #{token}"
    end

    def inject(text, newline: true)
      raise "session is not running" unless pid && Harnex.alive_pid?(pid)

      payload = text.dup
      payload << "\n" if newline

      written = @mutex.synchronize do
        bytes = @writer.write(payload)
        @writer.flush
        @injected_count += 1
        @last_injected_at = Time.now
        persist_registry
        bytes
      end

      {
        ok: true,
        bytes_written: written,
        injected_count: @injected_count,
        newline: newline
      }
    end

    def sync_window_size
      return unless STDIN.tty?

      @writer.winsize = STDIN.winsize
    rescue StandardError
      nil
    end

    private

    def registry_payload
      status_payload.merge(
        token: token,
        cwd: Dir.pwd
      )
    end

    def persist_registry
      Harnex.write_registry(@registry_path, registry_payload)
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
          @mutex.synchronize do
            @writer.write(chunk)
            @writer.flush
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
          STDOUT.write(chunk)
          STDOUT.flush
        rescue EOFError, Errno::EIO, IOError
          break
        end
      end
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
  end

  class ApiServer
    def initialize(session)
      @session = session
      @server = TCPServer.new(session.host, session.port)
      @server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
      @thread = nil
    end

    def start
      @thread = Thread.new do
        loop do
          socket = @server.accept
          Thread.new(socket) { |client| handle(client) }
        rescue IOError, Errno::EBADF
          break
        end
      end
    end

    def stop
      @server.close
      @thread&.join(1)
    rescue IOError, Errno::EBADF
      nil
    end

    private

    def handle(client)
      request_line = client.gets("\r\n")
      return unless request_line

      method, target, = request_line.split(" ", 3)
      headers = {}
      while (line = client.gets("\r\n"))
        line = line.strip
        break if line.empty?

        key, value = line.split(":", 2)
        headers[key.downcase] = value.to_s.strip
      end

      body = +""
      length = headers.fetch("content-length", "0").to_i
      body = client.read(length) if length.positive?

      path = target.to_s.split("?", 2).first

      case [method, path]
      when ["GET", "/health"], ["GET", "/status"]
        return unauthorized(client) unless authorized?(headers)

        json(client, 200, @session.status_payload)
      when ["POST", "/send"]
        return unauthorized(client) unless authorized?(headers)

        payload = parse_send_body(headers, body)
        return json(client, 400, ok: false, error: "text is required") if payload[:text].to_s.empty?

        json(client, 200, @session.inject(payload[:text], newline: payload[:newline]))
      else
        json(client, 404, ok: false, error: "not found")
      end
    rescue JSON::ParserError
      json(client, 400, ok: false, error: "invalid json")
    rescue StandardError => e
      json(client, 500, ok: false, error: e.message)
    ensure
      client.close unless client.closed?
    end

    def parse_send_body(headers, body)
      if headers["content-type"].to_s.include?("application/json")
        parsed = JSON.parse(body.empty? ? "{}" : body)
        {
          text: parsed["text"].to_s,
          newline: parsed.fetch("newline", true)
        }
      else
        {
          text: body.to_s,
          newline: true
        }
      end
    end

    def authorized?(headers)
      @session.auth_ok?(headers["authorization"].to_s)
    end

    def unauthorized(client)
      json(client, 401, ok: false, error: "unauthorized")
    end

    def json(client, code, payload)
      body = JSON.generate(payload)
      client.write("HTTP/1.1 #{code} #{http_reason(code)}\r\n")
      client.write("Content-Type: application/json\r\n")
      client.write("Content-Length: #{body.bytesize}\r\n")
      client.write("Connection: close\r\n")
      client.write("\r\n")
      client.write(body)
    end

    def http_reason(code)
      {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        500 => "Internal Server Error"
      }.fetch(code, "OK")
    end
  end

  class Sender
    def initialize(argv)
      @options = {
        repo_path: Dir.pwd,
        label: DEFAULT_LABEL,
        message: nil,
        submit: true,
        enter_only: false,
        status: false,
        port: nil,
        host: DEFAULT_HOST,
        wait_seconds: Float(Harnex.env_value("HARNEX_SEND_WAIT", legacy: "CXW_SEND_WAIT", default: "2.0")),
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
      debug("label=#{@options[:label]}")
      debug("registry_path=#{Harnex.registry_path(repo_root, @options[:label])}") unless @options[:port]
      registry = wait_for_registry(repo_root)

      if @options[:port]
        registry ||= {}
        registry["host"] ||= @options[:host]
        registry["port"] = @options[:port]
      end

      unless registry
        available = Harnex.active_sessions(repo_root).map { |session| session["label"] }.uniq.sort
        suffix =
          if available.empty?
            ""
          else
            " | active labels: #{available.join(', ')}"
          end
        raise "no active harnex session found for #{repo_root} (label: #{@options[:label]})#{suffix}"
      end

      uri = URI("http://#{registry.fetch('host', @options[:host])}:#{registry.fetch('port')}#{@options[:status] ? '/status' : '/send'}")
      debug("target=#{uri}")
      text = nil
      unless @options[:status]
        text = resolve_text
        raise "text is required" if text.to_s.empty? && !@options[:enter_only]
        text = "#{text}\r" if @options[:submit] || @options[:enter_only]
        debug("payload_bytes=#{text.bytesize} submit=#{@options[:submit]} enter_only=#{@options[:enter_only]}")
      end

      response = with_http_retry do
        request = @options[:status] ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{registry['token']}" if registry["token"]

        unless @options[:status]
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(text: text, newline: false)
        end

        Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
      end
      puts response.body
      response.is_a?(Net::HTTPSuccess) ? 0 : 1
    end

    private

    def resolve_text
      return "" if @options[:enter_only]

      @options[:message] || (@argv.empty? ? STDIN.read : @argv.join(" "))
    end

    def debug(message)
      return unless @options[:debug]

      warn("[harnex-send] #{message}")
    end

    def wait_for_registry(repo_root)
      return nil if @options[:port]

      deadline = Time.now + @options[:wait_seconds]
      loop do
        registry = Harnex.read_registry(repo_root, @options[:label])
        return registry if registry
        return nil if Time.now >= deadline

        sleep 0.1
      end
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
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: harnex-send [options] [text...]"
        opts.on("--repo PATH", "Resolve the active session using PATH's repo root") { |value| @options[:repo_path] = Harnex.ensure_option_value!("--repo", value) }
        opts.on("--label LABEL", "Target a labeled session in the current repo") { |value| @options[:label] = Harnex.normalize_label(Harnex.ensure_option_value!("--label", value)) }
        opts.on("--message TEXT", "Message text to inject without using positional args") { |value| @options[:message] = Harnex.ensure_option_value!("--message", value) }
        opts.on("--port PORT", Integer, "Send directly to a specific port") { |value| @options[:port] = value }
        opts.on("--host HOST", "Override the host when --port is used") { |value| @options[:host] = Harnex.ensure_option_value!("--host", value) }
        opts.on("--wait SECONDS", Float, "How long to wait for the target session to appear/respond") { |value| @options[:wait_seconds] = value }
        opts.on("--status", "Print session status instead of sending text") { @options[:status] = true }
        opts.on("--enter", "Send only Enter to submit the current prompt") do
          @options[:enter_only] = true
          @options[:submit] = true
        end
        opts.on("--no-submit", "Inject text without pressing Enter") { @options[:submit] = false }
        opts.on("--debug", "Print repo/session lookup details to stderr") { @options[:debug] = true }
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end
  end
end
