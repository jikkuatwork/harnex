require "digest"
require "fileutils"
require "io/console"
require "json"
require "net/http"
require "open3"
require "optparse"
require "pty"
require "securerandom"
require "socket"
require "time"
require "uri"

require_relative "harnex/adapters"

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
  DEFAULT_CLI = "codex"
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

  def configured_label
    value = env_value("HARNEX_LABEL", legacy: "CXW_LABEL")
    return nil if value.nil? || value.to_s.strip.empty?

    normalize_label(value)
  end

  def default_session_label(cli = DEFAULT_CLI)
    configured_label || normalize_label(cli || DEFAULT_CLI)
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

  def active_sessions(repo_root = nil)
    FileUtils.mkdir_p(SESSIONS_DIR)
    pattern =
      if repo_root
        File.join(SESSIONS_DIR, "#{repo_key(repo_root)}--*.json")
      else
        File.join(SESSIONS_DIR, "*.json")
      end

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

  def build_adapter(cli, argv)
    Adapters.build(cli || DEFAULT_CLI, argv)
  end

  class CLI
    def initialize(argv)
      @argv = argv.dup
    end

    def run
      case @argv.first
      when nil
        Runner.new([]).run
      when "run"
        Runner.new(@argv.drop(1)).run
      when "send"
        Sender.new(@argv.drop(1)).run
      when "status"
        Status.new(@argv.drop(1)).run
      when "help"
        puts help(@argv[1])
        0
      when "-h", "--help"
        puts usage
        0
      else
        Runner.new(@argv).run
      end
    end

    private

    def help(topic)
      case topic
      when "run"
        Runner.usage
      when "send"
        Sender.usage
      when "status"
        Status.usage
      else
        usage
      end
    end

    def usage
      <<~TEXT
        Usage:
          harnex run [cli] [wrapper-options] [--] [cli-args...]
          harnex send [options] [text...]
          harnex status [options]
          harnex [cli] [wrapper-options] [--] [cli-args...]

        Commands:
          run    Start a wrapped interactive session and local API
          send   Send text or inspect status for an active session
          status List live sessions for this repo

        Notes:
          The bare `harnex` form is an alias for `harnex run #{DEFAULT_CLI}`.
          Supported CLIs: #{Adapters.supported.join(', ')}

        Examples:
          harnex
          harnex run codex
          harnex run codex --label hello
          harnex run codex -- --cd /path/to/repo
          harnex status
          harnex send --label main --message "Summarize current progress."
      TEXT
    end
  end

  class Runner
    def self.usage(program_name = "harnex run")
      <<~TEXT
        Usage: #{program_name} [cli] [wrapper-options] [--] [cli-args...]

        Wrapper options:
          --label LABEL   Session label for this repo (default: adapter name)
          --host HOST     Bind host for the local API (default: #{DEFAULT_HOST})
          --port PORT     Force a specific local API port
          -h, --help      Show this help

        Notes:
          Supported CLIs: #{Adapters.supported.join(', ')}
          If `cli` is omitted, Harnex uses: #{DEFAULT_CLI}

          After `cli`, all remaining args are forwarded to that adapter's command.
          Wrapper options may appear before or after `cli`.
          Use `--` to forward args to the adapter without ambiguity.
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {
        label: Harnex.configured_label,
        host: DEFAULT_HOST,
        port: (env_port = Harnex.env_value("HARNEX_PORT", legacy: "CXW_PORT")) && Integer(env_port),
        help: false
      }
    end

    def run
      cli_name, child_args = extract_wrapper_options(@argv)
      if @options[:help]
        puts self.class.usage
        return 0
      end

      adapter = Harnex.build_adapter(cli_name, child_args)
      @options[:label] ||= Harnex.default_session_label(adapter.key)
      command = adapter.build_command
      repo_root = Harnex.resolve_repo_root(adapter.infer_repo_path(child_args))
      session = Session.new(
        adapter: adapter,
        command: command,
        repo_root: repo_root,
        host: @options[:host],
        port: @options[:port],
        label: @options[:label]
      )

      session.run
    end

    private

    def extract_wrapper_options(argv)
      cli_index = find_cli_index(argv)
      cli_name = nil
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
          if index == cli_index
            cli_name = arg
          else
            forwarded << arg
          end
        end
        index += 1
      end

      [cli_name, forwarded]
    end

    def find_cli_index(argv)
      index = 0
      while index < argv.length
        arg = argv[index]
        case arg
        when "--"
          break
        when "-h", "--help"
          nil
        when "--label", "--host", "--port"
          index += 1
        when /\A--(?:label|host)=(.+)\z/, /\A--port=(\d+)\z/
          nil
        else
          return index if Adapters.supported.include?(arg)
        end
        index += 1
      end

      nil
    end
  end

  Launcher = Runner

  class Session
    OUTPUT_BUFFER_LIMIT = 64 * 1024

    attr_reader :repo_root, :host, :port, :session_id, :token, :command, :pid, :label, :adapter

    def initialize(adapter:, command:, repo_root:, host:, port: nil, label: DEFAULT_LABEL)
      @adapter = adapter
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
      @output_buffer = +""
      @output_buffer.force_encoding(Encoding::BINARY)
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

    def status_payload(include_input_state: true)
      payload = {
        ok: true,
        session_id: session_id,
        repo_root: repo_root,
        repo_key: Harnex.repo_key(repo_root),
        cli: adapter.key,
        label: label,
        pid: pid,
        host: host,
        port: port,
        command: command,
        started_at: @started_at.iso8601,
        last_injected_at: @last_injected_at&.iso8601,
        injected_count: @injected_count
      }

      payload[:input_state] = adapter.input_state(screen_snapshot) if include_input_state
      payload
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

    def inject_via_adapter(text:, submit:, enter_only:, force: false)
      payload = adapter.build_send_payload(
        text: text,
        submit: submit,
        enter_only: enter_only,
        screen_text: screen_snapshot,
        force: force
      )

      inject(payload.fetch(:text), newline: payload.fetch(:newline, false)).merge(
        cli: adapter.key,
        input_state: payload[:input_state],
        force: payload[:force]
      )
    end

    def sync_window_size
      return unless STDIN.tty?

      @writer.winsize = STDIN.winsize
    rescue StandardError
      nil
    end

    private

    def registry_payload
      status_payload(include_input_state: false).merge(
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
          record_output(chunk)
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

    def record_output(chunk)
      @mutex.synchronize do
        @output_buffer << chunk
        overflow = @output_buffer.bytesize - OUTPUT_BUFFER_LIMIT
        @output_buffer = @output_buffer.byteslice(overflow, OUTPUT_BUFFER_LIMIT) if overflow.positive?
      end
    end

    def screen_snapshot
      @mutex.synchronize { @output_buffer.dup }
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
        if payload[:mode] == :adapter
          return json(client, 400, ok: false, error: "text is required") if payload[:text].to_s.empty? && !payload[:enter_only]

          json(
            client,
            200,
            @session.inject_via_adapter(
              text: payload[:text],
              submit: payload[:submit],
              enter_only: payload[:enter_only],
              force: payload[:force]
            )
          )
        else
          return json(client, 400, ok: false, error: "text is required") if payload[:text].to_s.empty?

          json(client, 200, @session.inject(payload[:text], newline: payload[:newline]))
        end
      else
        json(client, 404, ok: false, error: "not found")
      end
    rescue JSON::ParserError
      json(client, 400, ok: false, error: "invalid json")
    rescue ArgumentError => e
      json(client, 409, ok: false, error: e.message)
    rescue StandardError => e
      json(client, 500, ok: false, error: e.message)
    ensure
      client.close unless client.closed?
    end

    def parse_send_body(headers, body)
      if headers["content-type"].to_s.include?("application/json")
        parsed = JSON.parse(body.empty? ? "{}" : body)
        if parsed.key?("submit") || parsed.key?("enter_only") || parsed.key?("force")
          {
            mode: :adapter,
            text: parsed["text"].to_s,
            submit: parsed.fetch("submit", true),
            enter_only: parsed.fetch("enter_only", false),
            force: parsed.fetch("force", false)
          }
        else
          {
            mode: :legacy,
            text: parsed["text"].to_s,
            newline: parsed.fetch("newline", true)
          }
        end
      else
        {
          mode: :legacy,
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
        409 => "Conflict",
        404 => "Not Found",
        500 => "Internal Server Error"
      }.fetch(code, "OK")
    end
  end

  class Status
    def self.usage(program_name = "harnex status")
      <<~TEXT
        Usage: #{program_name} [options]

        Options:
          --repo PATH   List sessions for PATH's repo root (default: current repo)
          --all         List sessions across all repos
          -h, --help    Show this help
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {
        repo_path: Dir.pwd,
        all: false,
        help: false
      }
    end

    def run
      parser.parse!(@argv)
      if @options[:help]
        puts self.class.usage
        return 0
      end

      sessions = load_sessions
      if sessions.empty?
        if @options[:all]
          puts "No active harnex sessions."
        else
          puts "No active harnex sessions for #{Harnex.resolve_repo_root(@options[:repo_path])}."
        end
        return 0
      end

      puts render_table(sessions)
      0
    end

    private

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: harnex status [options]"
        opts.on("--repo PATH", "List sessions for PATH's repo root") { |value| @options[:repo_path] = Harnex.ensure_option_value!("--repo", value) }
        opts.on("--all", "List sessions across all repos") { @options[:all] = true }
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end

    def load_sessions
      sessions =
        if @options[:all]
          Harnex.active_sessions
        else
          Harnex.active_sessions(Harnex.resolve_repo_root(@options[:repo_path]))
        end

      sessions.map { |session| load_live_status(session) }
        .sort_by { |session| [session["repo_root"].to_s, session["started_at"].to_s, session["label"].to_s] }
        .reverse
    end

    def load_live_status(session)
      uri = URI("http://#{session.fetch('host')}:#{session.fetch('port')}/status")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{session['token']}" if session["token"]

      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 0.25, read_timeout: 0.25) do |http|
        http.request(request)
      end

      return session unless response.is_a?(Net::HTTPSuccess)

      session.merge(JSON.parse(response.body))
    rescue StandardError
      session
    end

    def render_table(sessions)
      columns = ["LABEL", "CLI", "PID", "PORT", "AGE", "LAST", "STATE"]
      columns << "REPO" if @options[:all]

      rows = sessions.map { |session| table_row(session, columns) }
      widths = columns.to_h { |column| [column, ([column.length] + rows.map { |row| row.fetch(column).length }).max] }

      lines = []
      lines << format_row(columns.to_h { |column| [column, column] }, columns, widths)
      lines << format_row(columns.to_h { |column| [column, "-" * widths.fetch(column)] }, columns, widths)
      lines.concat(rows.map { |row| format_row(row, columns, widths) })
      lines.join("\n")
    end

    def table_row(session, columns)
      row = {
        "LABEL" => session["label"].to_s,
        "CLI" => (session["cli"] || session.fetch("command", []).first || "-").to_s,
        "PID" => session["pid"].to_s,
        "PORT" => session["port"].to_s,
        "AGE" => timeago(session["started_at"]),
        "LAST" => timeago(session["last_injected_at"], none: "never"),
        "STATE" => session.dig("input_state", "state").to_s.empty? ? "-" : session.dig("input_state", "state").to_s
      }
      row["REPO"] = display_path(session["repo_root"]) if columns.include?("REPO")
      row
    end

    def format_row(row, columns, widths)
      columns.map { |column| row.fetch(column).ljust(widths.fetch(column)) }.join("  ")
    end

    def timeago(timestamp, none: "-")
      return none if timestamp.to_s.empty?

      seconds = (Time.now - Time.parse(timestamp.to_s)).to_i
      seconds = 0 if seconds.negative?

      case seconds
      when 0...60
        "#{seconds}s ago"
      when 60...3600
        "#{seconds / 60}m ago"
      when 3600...86_400
        "#{seconds / 3600}h ago"
      else
        "#{seconds / 86_400}d ago"
      end
    rescue StandardError
      timestamp.to_s
    end

    def display_path(path)
      path.to_s.sub(/\A#{Regexp.escape(Dir.home)}/, "~")
    end
  end

  class Sender
    def self.build_parser(options, program_name = "harnex send")
      OptionParser.new do |opts|
        opts.banner = "Usage: #{program_name} [options] [text...]"
        opts.on("--repo PATH", "Resolve the active session using PATH's repo root") { |value| options[:repo_path] = Harnex.ensure_option_value!("--repo", value) }
        opts.on("--label LABEL", "Target a labeled session in the current repo") { |value| options[:label] = Harnex.normalize_label(Harnex.ensure_option_value!("--label", value)) }
        opts.on("--message TEXT", "Message text to inject without using positional args") { |value| options[:message] = Harnex.ensure_option_value!("--message", value) }
        opts.on("--port PORT", Integer, "Send directly to a specific port") { |value| options[:port] = value }
        opts.on("--host HOST", "Override the host when --port is used") { |value| options[:host] = Harnex.ensure_option_value!("--host", value) }
        opts.on("--wait SECONDS", Float, "How long to wait for the target session to appear/respond") { |value| options[:wait_seconds] = value }
        opts.on("--status", "Print session status instead of sending text") { options[:status] = true }
        opts.on("--enter", "Send only Enter to submit the current prompt") do
          options[:enter_only] = true
          options[:submit] = true
        end
        opts.on("--no-submit", "Inject text without pressing Enter") { options[:submit] = false }
        opts.on("--force", "Send input even if the adapter says the UI is not at a prompt") { options[:force] = true }
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
        label: Harnex.configured_label,
        message: nil,
        submit: true,
        enter_only: false,
        force: false,
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
      debug("label=#{@options[:label] || '(auto)'}")
      debug("registry_path=#{Harnex.registry_path(repo_root, @options[:label])}") if @options[:label] && !@options[:port]
      registry = wait_for_registry(repo_root)

      if @options[:port]
        registry ||= {}
        registry["host"] ||= @options[:host]
        registry["port"] = @options[:port]
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
        raise "text is required" if text.to_s.empty? && !@options[:enter_only]
        debug("payload_bytes=#{text.bytesize} submit=#{@options[:submit]} enter_only=#{@options[:enter_only]} force=#{@options[:force]}")
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
      if @options[:label]
        Harnex.read_registry(repo_root, @options[:label]) || :retry
      else
        sessions = Harnex.active_sessions(repo_root)
        return :retry if sessions.empty?
        return sessions.first if sessions.length == 1

        :ambiguous
      end
    end

    def missing_session_message(repo_root)
      base = "no active harnex session found for #{repo_root}"
      return "#{base} (label: #{@options[:label]})" if @options[:label]

      available = Harnex.active_sessions(repo_root).map { |session| session["label"] }.uniq.sort
      suffix = available.empty? ? "" : " | active labels: #{available.join(', ')}"
      "#{base}#{suffix}"
    end

    def ambiguous_session_message(repo_root)
      available = Harnex.active_sessions(repo_root)
      detail = available.map { |session| "#{session['label']}(#{session['cli'] || session.fetch('command', []).first})" }.join(", ")
      "multiple active harnex sessions found for #{repo_root}; use --label or `harnex status` | active: #{detail}"
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
