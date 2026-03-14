require "digest"
require "fileutils"
require "fiddle/import"
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
  DEFAULT_ID = env_value("HARNEX_ID", legacy: "HARNEX_LABEL", default: "default")
  DEFAULT_CLI = "codex"
  WATCH_DEBOUNCE_SECONDS = 1.0
  STATE_DIR = File.expand_path(env_value("HARNEX_STATE_DIR", legacy: "CXW_STATE_DIR", default: "~/.local/state/harnex"))
  SESSIONS_DIR = File.join(STATE_DIR, "sessions")
  WatchConfig = Struct.new(:absolute_path, :display_path, :hook_message, :debounce_seconds, keyword_init: true)

  module LinuxInotify
    extend Fiddle::Importer

    IN_ATTRIB = 0x00000004
    IN_CLOSE_WRITE = 0x00000008
    IN_CREATE = 0x00000100
    IN_MOVED_TO = 0x00000080

    @available = false
    begin
      dlload Fiddle.dlopen(nil)
      extern "int inotify_init(void)"
      extern "int inotify_add_watch(int, const char*, unsigned int)"
      @available = true
    rescue Fiddle::DLError
      @available = false
    end

    class << self
      def available?
        @available
      end

      def directory_io(path, mask)
        raise "file watch is unsupported on this system" unless available?

        fd = inotify_init
        raise "could not initialize file watch" if fd.negative?

        watch_id = inotify_add_watch(fd, path, mask)
        if watch_id.negative?
          IO.for_fd(fd, autoclose: true)&.close
          raise "could not watch #{path}"
        end

        IO.for_fd(fd, "rb", autoclose: true)
      end
    end
  end

  def resolve_repo_root(path = Dir.pwd)
    output, status = Open3.capture2("git", "rev-parse", "--show-toplevel", chdir: path)
    status.success? ? output.strip : File.expand_path(path)
  rescue StandardError
    File.expand_path(path)
  end

  def repo_key(repo_root)
    Digest::SHA256.hexdigest(repo_root)[0, 16]
  end

  def normalize_id(id)
    value = id.to_s.strip
    raise "id is required" if value.empty?

    value
  end

  def id_key(id)
    normalize_id(id).downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
  end

  def cli_key(cli)
    value = cli.to_s.strip.downcase
    return nil if value.empty?

    value.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
  end

  def configured_id
    value = env_value("HARNEX_ID", legacy: "HARNEX_LABEL")
    return nil if value.nil? || value.to_s.strip.empty?

    normalize_id(value)
  end

  def default_id(cli = DEFAULT_CLI)
    configured_id || normalize_id(cli || DEFAULT_CLI)
  end

  def current_session_context(env = ENV)
    session_id = env["HARNEX_SESSION_ID"].to_s.strip
    cli = env["HARNEX_SESSION_CLI"].to_s.strip
    id = (env["HARNEX_ID"] || env["HARNEX_SESSION_LABEL"]).to_s.strip
    repo_root = env["HARNEX_SESSION_REPO_ROOT"].to_s.strip
    return nil if session_id.empty? || cli.empty? || id.empty?

    {
      session_id: session_id,
      cli: cli,
      id: id,
      repo_root: repo_root.empty? ? nil : repo_root
    }
  end

  def format_relay_message(text, from:, id:, at: Time.now)
    header = "[harnex relay from=#{from} id=#{normalize_id(id)} at=#{at.iso8601}]"
    body = text.to_s
    return header if body.empty?

    "#{header}\n#{body}"
  end

  def suspicious_option_value?(value)
    value.to_s.start_with?("-")
  end

  def ensure_option_value!(option_name, value)
    return value unless suspicious_option_value?(value)

    raise ArgumentError, "#{option_name} requires a value"
  end

  def registry_path(repo_root, id = DEFAULT_ID)
    FileUtils.mkdir_p(SESSIONS_DIR)
    slug = id_key(id)
    slug = "default" if slug.empty?
    File.join(SESSIONS_DIR, "#{repo_key(repo_root)}--#{slug}.json")
  end

  def active_sessions(repo_root = nil, id: nil, cli: nil)
    FileUtils.mkdir_p(SESSIONS_DIR)
    pattern =
      if repo_root
        File.join(SESSIONS_DIR, "#{repo_key(repo_root)}--*.json")
      else
        File.join(SESSIONS_DIR, "*.json")
      end

    normalized_id = id.nil? ? nil : normalize_id(id)
    normalized_cli = cli_key(cli)

    Dir.glob(pattern).sort.filter_map do |path|
      data = JSON.parse(File.read(path))
      if data["pid"] && alive_pid?(data["pid"])
        session = data.merge("registry_path" => path)
        next if normalized_id && session["id"].to_s != normalized_id
        next if normalized_cli && cli_key(session_cli(session)) != normalized_cli

        session
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

  def read_registry(repo_root, id = DEFAULT_ID, cli: nil)
    sessions = active_sessions(repo_root, id: id, cli: cli)
    return nil unless sessions.length == 1

    sessions.first
  end

  def write_registry(path, payload)
    tmp = "#{path}.tmp.#{Process.pid}"
    File.write(tmp, JSON.pretty_generate(payload))
    File.rename(tmp, path)
  end

  def allocate_port(repo_root, id, requested_port = nil, host: DEFAULT_HOST)
    if requested_port
      return requested_port if port_available?(host, requested_port)

      raise "port #{requested_port} is already in use on #{host}"
    end

    seed = Digest::SHA256.hexdigest("#{repo_root}\0#{normalize_id(id)}").to_i(16)
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

  def session_cli(session)
    (session["cli"] || Array(session["command"]).first).to_s
  end

  def build_watch_config(path, repo_root)
    return nil if path.nil?

    raise "file watch is unsupported on this system" unless LinuxInotify.available?

    display_path = path.to_s.strip
    raise ArgumentError, "--watch requires a value" if display_path.empty?

    display_path = ensure_option_value!("--watch", display_path)
    absolute_path = File.expand_path(display_path, repo_root)
    FileUtils.mkdir_p(File.dirname(absolute_path))

    WatchConfig.new(
      absolute_path: absolute_path,
      display_path: display_path,
      hook_message: "file-change-hook: read #{display_path}",
      debounce_seconds: WATCH_DEBOUNCE_SECONDS
    )
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
      when "wait"
        Waiter.new(@argv.drop(1)).run
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
      when "wait"
        Waiter.usage
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
          harnex wait --id ID [options]
          harnex status [options]
          harnex [cli] [wrapper-options] [--] [cli-args...]

        Commands:
          run    Start a wrapped interactive session and local API
          send   Send text or inspect status for an active session
          wait   Block until a detached session exits
          status List live sessions for this repo

        Notes:
          The bare `harnex` form is an alias for `harnex run #{DEFAULT_CLI}`.
          Supported CLIs: #{Adapters.supported.join(', ')}

        Examples:
          harnex
          harnex run codex
          harnex run codex --id hello
          harnex run codex -- --cd /path/to/repo
          harnex status
          harnex send --id main --message "Summarize current progress."
      TEXT
    end
  end

  class Runner
    def self.usage(program_name = "harnex run")
      <<~TEXT
        Usage: #{program_name} [cli] [wrapper-options] [--] [cli-args...]

        Wrapper options:
          --id ID         Session ID (default: adapter name)
          --detach        Start session in background and return immediately
          --tmux [NAME]   Run detached session in a tmux window (implies --detach)
                          NAME sets the window title (default: session ID)
                          Tip: keep names terse (e.g. "cx-p3", "cl-r3") for narrow tab bars
          --host HOST     Bind host for the local API (default: #{DEFAULT_HOST})
          --port PORT     Force a specific local API port
          --watch PATH    Watch PATH and auto-send a file-change hook after 1s quiet time
          --context TEXT   Prepend context as initial prompt (auto-includes session ID)
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
        id: Harnex.configured_id,
        host: DEFAULT_HOST,
        port: (env_port = Harnex.env_value("HARNEX_PORT", legacy: "CXW_PORT")) && Integer(env_port),
        watch: nil,
        context: nil,
        detach: false,
        tmux: false,
        tmux_name: nil,
        help: false
      }
    end

    def run
      cli_name, child_args = extract_wrapper_options(@argv)
      if @options[:help]
        puts self.class.usage
        return 0
      end

      # ID must be resolved before apply_context uses it
      @options[:id] ||= Harnex.default_id(cli_name || DEFAULT_CLI)
      child_args = apply_context(child_args)
      adapter = Harnex.build_adapter(cli_name, child_args)
      @options[:detach] = true if @options[:tmux]

      if @options[:detach]
        run_detached(adapter, cli_name, child_args)
      else
        run_foreground(adapter, child_args)
      end
    end

    def run_foreground(adapter, child_args)
      command = adapter.build_command
      repo_root = Harnex.resolve_repo_root(adapter.infer_repo_path(child_args))
      watch = Harnex.build_watch_config(@options[:watch], repo_root)
      session = Session.new(
        adapter: adapter,
        command: command,
        repo_root: repo_root,
        host: @options[:host],
        port: @options[:port],
        id: @options[:id],
        watch: watch
      )

      session.run
    end

    def run_detached(adapter, cli_name, child_args)
      if @options[:tmux]
        run_in_tmux(cli_name, child_args)
      else
        run_headless(adapter, child_args)
      end
    end

    def run_in_tmux(cli_name, child_args)
      # Build the harnex command to run inside the tmux window (foreground, no --detach)
      harnex_bin = File.expand_path("../../bin/harnex", __dir__)
      tmux_cmd = [harnex_bin, "run"]
      tmux_cmd << cli_name if cli_name
      tmux_cmd += ["--id", @options[:id]]
      tmux_cmd += ["--host", @options[:host]]
      tmux_cmd += ["--port", @options[:port].to_s] if @options[:port]
      tmux_cmd += ["--watch", @options[:watch]] if @options[:watch]
      tmux_cmd += ["--"] + child_args unless child_args.empty?

      window_name = @options[:tmux_name] || @options[:id]
      shell_cmd = tmux_cmd.map { |a| Shellwords.shellescape(a) }.join(" ")

      # Try current tmux session first, fall back to creating a new session
      if ENV["TMUX"]
        system("tmux", "new-window", "-n", window_name, "-d", shell_cmd)
      else
        system("tmux", "new-session", "-d", "-s", "harnex", "-n", window_name, shell_cmd)
      end

      # Wait briefly for the session to register
      deadline = Time.now + 5.0
      registry = nil
      repo_root = Harnex.resolve_repo_root(adapter_repo_path(cli_name, child_args))
      while Time.now < deadline
        registry = Harnex.read_registry(repo_root, @options[:id])
        break if registry
        sleep 0.1
      end

      if registry
        puts JSON.generate(
          ok: true,
          id: @options[:id],
          cli: cli_name || DEFAULT_CLI,
          pid: registry["pid"],
          port: registry["port"],
          mode: "tmux",
          window: window_name
        )
        0
      else
        warn("harnex: detached session #{@options[:id]} did not register within 5s")
        1
      end
    end

    def run_headless(adapter, child_args)
      repo_root = Harnex.resolve_repo_root(adapter.infer_repo_path(child_args))
      log_dir = File.join(Harnex::STATE_DIR, "logs")
      FileUtils.mkdir_p(log_dir)
      log_path = File.join(log_dir, "#{@options[:id]}.log")

      child_pid = fork do
        Process.setsid
        STDIN.reopen("/dev/null")
        log_file = File.open(log_path, "a")
        STDOUT.reopen(log_file)
        STDERR.reopen(log_file)
        STDOUT.sync = true
        STDERR.sync = true

        watch = Harnex.build_watch_config(@options[:watch], repo_root)
        session = Session.new(
          adapter: adapter,
          command: adapter.build_command,
          repo_root: repo_root,
          host: @options[:host],
          port: @options[:port],
          id: @options[:id],
          watch: watch
        )

        exit_code = session.run
        exit(exit_code || 1)
      end

      Process.detach(child_pid)

      # Wait briefly for the session to register
      deadline = Time.now + 5.0
      registry = nil
      while Time.now < deadline
        registry = Harnex.read_registry(repo_root, @options[:id])
        break if registry
        sleep 0.1
      end

      if registry
        puts JSON.generate(
          ok: true,
          id: @options[:id],
          cli: adapter.key,
          pid: registry["pid"],
          port: registry["port"],
          mode: "headless",
          log: log_path
        )
        0
      else
        warn("harnex: detached session #{@options[:id]} did not register within 5s")
        1
      end
    end

    def adapter_repo_path(cli_name, child_args)
      adapter = Harnex.build_adapter(cli_name, child_args)
      adapter.infer_repo_path(child_args)
    end

    # Append context string (with session ID) to child args as the initial prompt.
    # Both codex and claude accept a trailing positional [PROMPT] argument.
    def apply_context(child_args)
      return child_args unless @options[:context]

      context = "[harnex session id=#{@options[:id]}] #{@options[:context]}"
      child_args + [context]
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
        when "--id", "--label"
          index += 1
          raise OptionParser::MissingArgument, arg if index >= argv.length
          @options[:id] = Harnex.normalize_id(Harnex.ensure_option_value!(arg, argv[index]))
        when /\A--(?:id|label)=(.+)\z/
          @options[:id] = Harnex.normalize_id(Regexp.last_match(1))
        when "--detach"
          @options[:detach] = true
        when "--tmux"
          @options[:tmux] = true
          # Peek at next arg — if it's not a flag or CLI name, treat as window name
          if index + 1 < argv.length && !argv[index + 1].start_with?("-") && !Adapters.supported.include?(argv[index + 1])
            index += 1
            @options[:tmux_name] = argv[index]
          end
        when /\A--tmux=(.+)\z/
          @options[:tmux] = true
          @options[:tmux_name] = Regexp.last_match(1)
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
        when "--watch"
          index += 1
          raise OptionParser::MissingArgument, "--watch" if index >= argv.length
          @options[:watch] = Harnex.ensure_option_value!("--watch", argv[index])
        when /\A--watch=(.+)\z/
          @options[:watch] = Harnex.ensure_option_value!("--watch", Regexp.last_match(1))
        when "--context"
          index += 1
          raise OptionParser::MissingArgument, "--context" if index >= argv.length
          @options[:context] = Harnex.ensure_option_value!("--context", argv[index])
        when /\A--context=(.+)\z/
          @options[:context] = Harnex.ensure_option_value!("--context", Regexp.last_match(1))
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
        when "-h", "--help", "--detach"
          nil
        when "--tmux"
          # Skip optional name argument if present
          if index + 1 < argv.length && !argv[index + 1].start_with?("-") && !Adapters.supported.include?(argv[index + 1])
            index += 1
          end
        when "--id", "--label", "--host", "--port", "--watch"
          index += 1
        when /\A--(?:id|label|host|watch|tmux)=(.+)\z/, /\A--port=(\d+)\z/
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

  class SessionState
    STATES = %i[prompt busy blocked unknown].freeze

    attr_reader :state

    def initialize(adapter)
      @adapter = adapter
      @state = :unknown
      @mutex = Mutex.new
      @condvar = ConditionVariable.new
    end

    def update(screen_snapshot)
      input = @adapter.input_state(screen_snapshot)
      new_state =
        case input[:input_ready]
        when true  then :prompt
        when false then :blocked
        else            :unknown
        end

      @mutex.synchronize do
        old = @state
        @state = new_state
        @condvar.broadcast if old != new_state
      end

      new_state
    end

    def force_busy!
      @mutex.synchronize do
        @state = :busy
        @condvar.broadcast
      end
    end

    def wait_for_prompt(timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @mutex.synchronize do
        loop do
          return true if @state == :prompt
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return false if remaining <= 0
          @condvar.wait(@mutex, remaining)
        end
      end
    end

    def to_s
      @mutex.synchronize { @state.to_s }
    end
  end

  Message = Struct.new(:id, :text, :submit, :enter_only, :force, :queued_at, :status, :delivered_at, :error, keyword_init: true) do
    def to_h
      {
        id: id,
        status: status.to_s,
        queued_at: queued_at&.iso8601,
        delivered_at: delivered_at&.iso8601,
        error: error
      }
    end
  end

  class Inbox
    MAX_PENDING = 64
    DELIVERY_TIMEOUT = 300

    def initialize(session, state_machine)
      @session = session
      @state_machine = state_machine
      @queue = []
      @messages = {}
      @mutex = Mutex.new
      @condvar = ConditionVariable.new
      @thread = nil
      @running = false
      @delivered_total = 0
    end

    def start
      @running = true
      @thread = Thread.new { delivery_loop }
    end

    def stop
      @running = false
      @mutex.synchronize { @condvar.broadcast }
      @thread&.join(2)
      @thread&.kill
    end

    def enqueue(text:, submit:, enter_only:, force: false)
      msg = Message.new(
        id: SecureRandom.hex(8),
        text: text,
        submit: submit,
        enter_only: enter_only,
        force: force,
        queued_at: Time.now,
        status: :queued
      )

      # Force messages bypass the queue entirely
      if force
        return deliver_now(msg)
      end

      # Fast path: prompt ready and queue empty — deliver immediately
      @mutex.synchronize do
        if @queue.empty? && @state_machine.state == :prompt
          result = deliver_now(msg)
          return result if msg.status == :delivered
          # Fall through to queue if delivery failed
          msg.status = :queued
          msg.error = nil
        end

        raise "inbox full (#{MAX_PENDING} pending messages)" if @queue.size >= MAX_PENDING

        @queue << msg
        @messages[msg.id] = msg
        @condvar.broadcast
      end

      { ok: true, status: "queued", message_id: msg.id, http_status: 202 }
    end

    def message_status(id)
      @mutex.synchronize do
        msg = @messages[id]
        return nil unless msg
        msg.to_h
      end
    end

    def stats
      @mutex.synchronize do
        { pending: @queue.size, delivered_total: @delivered_total }
      end
    end

    private

    def deliver_now(msg)
      result = @session.inject_via_adapter(
        text: msg.text,
        submit: msg.submit,
        enter_only: msg.enter_only,
        force: msg.force
      )
      msg.status = :delivered
      msg.delivered_at = Time.now
      @mutex.synchronize do
        @delivered_total += 1
        @messages[msg.id] = msg
      end
      result.merge(ok: true, status: "delivered", message_id: msg.id, http_status: 200)
    rescue ArgumentError => e
      msg.status = :failed
      msg.error = e.message
      @mutex.synchronize { @messages[msg.id] = msg }
      raise
    end

    def delivery_loop
      while @running
        msg = @mutex.synchronize do
          while @queue.empty? && @running
            @condvar.wait(@mutex, 1.0)
          end
          @queue.first
        end

        break unless @running
        next unless msg

        ready = @state_machine.wait_for_prompt(DELIVERY_TIMEOUT)
        unless ready
          next if @running # Keep waiting
        end

        begin
          deliver_now(msg)
          @mutex.synchronize { @queue.shift }
        rescue ArgumentError
          # State race — will retry on next loop iteration
          sleep 0.1
        rescue StandardError => e
          msg.status = :failed
          msg.error = e.message
          @mutex.synchronize do
            @queue.shift
            @messages[msg.id] = msg
          end
        end
      end
    end
  end

  class Session
    OUTPUT_BUFFER_LIMIT = 64 * 1024

    attr_reader :repo_root, :host, :port, :session_id, :token, :command, :pid, :id, :adapter, :watch, :inbox

    def initialize(adapter:, command:, repo_root:, host:, port: nil, id: DEFAULT_ID, watch: nil)
      @adapter = adapter
      @command = command
      @repo_root = repo_root
      @host = host
      @id = Harnex.normalize_id(id)
      @watch = watch
      @registry_path = Harnex.registry_path(repo_root, @id)
      @session_id = SecureRandom.hex(8)
      @token = SecureRandom.hex(16)
      @port = Harnex.allocate_port(repo_root, @id, port, host: host)
      @mutex = Mutex.new
      @inject_mutex = Mutex.new
      @injected_count = 0
      @last_injected_at = nil
      @started_at = Time.now
      @server = nil
      @reader = nil
      @writer = nil
      @pid = nil
      @output_buffer = +""
      @output_buffer.force_encoding(Encoding::BINARY)
      @state_machine = SessionState.new(adapter)
      @inbox = Inbox.new(self, @state_machine)
    end

    def run
      @reader, @writer, @pid = PTY.spawn(child_env, *command)
      @writer.sync = true

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
      @exit_code = status.exited? ? status.exitstatus : 128 + status.termsig

      output_thread.join(1)
      input_thread&.kill
      watch_thread&.kill
      @exit_code
    ensure
      @inbox.stop
      STDIN.cooked! if STDIN.tty? && stdin_state
      @server&.stop
      persist_exit_status
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
        id: id,
        pid: pid,
        host: host,
        port: port,
        command: command,
        started_at: @started_at.iso8601,
        last_injected_at: @last_injected_at&.iso8601,
        injected_count: @injected_count
      }

      if watch
        payload[:watch_path] = watch.display_path
        payload[:watch_absolute_path] = watch.absolute_path
        payload[:watch_debounce_seconds] = watch.debounce_seconds
      end

      payload[:input_state] = adapter.input_state(screen_snapshot) if include_input_state
      payload[:agent_state] = @state_machine.to_s
      payload[:inbox] = @inbox.stats
      payload
    end

    def auth_ok?(header)
      header == "Bearer #{token}"
    end

    def inject(text, newline: true)
      raise "session is not running" unless pid && Harnex.alive_pid?(pid)

      inject_sequence([{ text: text, newline: newline }])
    end

    def inject_via_adapter(text:, submit:, enter_only:, force: false)
      snapshot = wait_for_sendable_snapshot(submit: submit, enter_only: enter_only, force: force)
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
    end

    def sync_window_size
      return unless STDIN.tty?

      @writer.winsize = STDIN.winsize
    rescue StandardError
      nil
    end

    private

    def child_env
      {
        "HARNEX_SESSION_ID" => session_id,
        "HARNEX_SESSION_CLI" => adapter.key,
        "HARNEX_ID" => id,
        "HARNEX_SESSION_REPO_ROOT" => repo_root
      }
    end

    def wait_for_sendable_snapshot(submit:, enter_only:, force:)
      snapshot = screen_snapshot
      return snapshot if force

      wait_seconds = adapter.send_wait_seconds(submit: submit, enter_only: enter_only).to_f
      return snapshot unless wait_seconds.positive?

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_seconds
      state = adapter.input_state(snapshot)

      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline &&
            adapter.wait_for_sendable_state?(state, submit: submit, enter_only: enter_only)
        sleep 0.05
        snapshot = screen_snapshot
        state = adapter.input_state(snapshot)
      end

      snapshot
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
        cwd: Dir.pwd
      )
    end

    def persist_registry
      Harnex.write_registry(@registry_path, registry_payload)
    end

    def persist_exit_status
      exit_dir = File.join(Harnex::STATE_DIR, "exits")
      FileUtils.mkdir_p(exit_dir)
      exit_path = File.join(exit_dir, "#{id}.json")
      payload = {
        ok: true,
        id: id,
        cli: adapter.key,
        session_id: session_id,
        exit_code: @exit_code,
        started_at: @started_at.iso8601,
        exited_at: Time.now.iso8601,
        injected_count: @injected_count
      }
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
        @output_buffer << chunk
        overflow = @output_buffer.bytesize - OUTPUT_BUFFER_LIMIT
        @output_buffer = @output_buffer.byteslice(overflow, OUTPUT_BUFFER_LIMIT) if overflow.positive?
        @output_buffer.dup
      end
      @state_machine.update(snapshot)
    end

    def screen_snapshot
      @mutex.synchronize { @output_buffer.dup }
    end
  end

  class FileChangeHook
    EVENT_HEADER_SIZE = 16
    WATCH_MASK = LinuxInotify::IN_ATTRIB | LinuxInotify::IN_CLOSE_WRITE | LinuxInotify::IN_CREATE | LinuxInotify::IN_MOVED_TO
    RETRY_SECONDS = 1.0
    IDLE_SLEEP_SECONDS = 0.1

    def initialize(session, config)
      @session = session
      @config = config
      @target_dir = File.dirname(config.absolute_path)
      @target_name = File.basename(config.absolute_path)
      @buffer = +""
      @buffer.force_encoding(Encoding::BINARY)
      @mutex = Mutex.new
      @change_generation = 0
      @delivered_generation = 0
      @last_change_at = nil
    end

    def start
      Thread.new { run }
    end

    private

    def run
      reader_thread = Thread.new { watch_loop }
      delivery_loop
    ensure
      reader_thread&.kill
      reader_thread&.join(0.1)
    end

    def watch_loop
      io = LinuxInotify.directory_io(@target_dir, WATCH_MASK)
      loop do
        chunk = io.readpartial(4096)
        note_change if relevant_change?(chunk)
      rescue EOFError, IOError, Errno::EIO
        break
      end
    ensure
      io&.close unless io&.closed?
    end

    def delivery_loop
      loop do
        generation, delivered_generation, last_change_at = snapshot
        if generation == delivered_generation || last_change_at.nil?
          sleep IDLE_SLEEP_SECONDS
          next
        end

        remaining = @config.debounce_seconds - (Time.now - last_change_at)
        if remaining.positive?
          sleep [remaining, IDLE_SLEEP_SECONDS].max
          next
        end

        begin
          @session.inbox.enqueue(
            text: @config.hook_message,
            submit: true,
            enter_only: false,
            force: false
          )
          mark_delivered
        rescue StandardError => e
          break if e.message == "session is not running"

          sleep RETRY_SECONDS
        end
      end
    end

    def relevant_change?(chunk)
      @buffer << chunk
      changed = false

      while @buffer.bytesize >= EVENT_HEADER_SIZE
        _, mask, _, name_length = @buffer.byteslice(0, EVENT_HEADER_SIZE).unpack("iIII")
        event_size = EVENT_HEADER_SIZE + name_length
        break if @buffer.bytesize < event_size

        name = @buffer.byteslice(EVENT_HEADER_SIZE, name_length).to_s.delete("\0")
        changed ||= name == @target_name && (mask & WATCH_MASK).positive?
        @buffer = @buffer.byteslice(event_size, @buffer.bytesize - event_size).to_s
      end

      changed
    end

    def note_change
      @mutex.synchronize do
        @change_generation += 1
        @last_change_at = Time.now
      end
    end

    def snapshot
      @mutex.synchronize { [@change_generation, @delivered_generation, @last_change_at] }
    end

    def mark_delivered
      @mutex.synchronize do
        @delivered_generation = @change_generation
      end
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

          result = @session.inbox.enqueue(
            text: payload[:text],
            submit: payload[:submit],
            enter_only: payload[:enter_only],
            force: payload[:force]
          )
          http_code = result.delete(:http_status) || 200
          json(client, http_code, result)
        else
          return json(client, 400, ok: false, error: "text is required") if payload[:text].to_s.empty?

          json(client, 200, @session.inject(payload[:text], newline: payload[:newline]))
        end
      else
        if method == "GET" && path =~ %r{\A/messages/([a-f0-9]+)\z}
          return unauthorized(client) unless authorized?(headers)

          msg_id = Regexp.last_match(1)
          msg = @session.inbox.message_status(msg_id)
          if msg
            json(client, 200, msg)
          else
            json(client, 404, ok: false, error: "message not found")
          end
        else
          json(client, 404, ok: false, error: "not found")
        end
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
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        409 => "Conflict",
        404 => "Not Found",
        500 => "Internal Server Error"
      }.fetch(code, "OK")
    end
  end

  class Waiter
    POLL_INTERVAL = 0.5

    def self.usage(program_name = "harnex wait")
      <<~TEXT
        Usage: #{program_name} [options]

        Options:
          --id ID         Session ID to wait for (required)
          --repo PATH     Resolve session using PATH's repo root (default: current repo)
          --timeout SECS  Maximum time to wait in seconds (default: unlimited)
          -h, --help      Show this help
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {
        id: nil,
        repo_path: Dir.pwd,
        timeout: nil,
        help: false
      }
    end

    def run
      parser.parse!(@argv)
      if @options[:help]
        puts self.class.usage
        return 0
      end

      raise "--id is required for harnex wait" unless @options[:id]

      repo_root = Harnex.resolve_repo_root(@options[:repo_path])
      deadline = @options[:timeout] ? Time.now + @options[:timeout] : nil

      # First, confirm the session exists
      registry = Harnex.read_registry(repo_root, @options[:id])
      unless registry
        warn("harnex wait: no session found with id #{@options[:id].inspect}")
        return 1
      end

      target_pid = registry["pid"]
      warn("harnex wait: watching session #{@options[:id]} (pid #{target_pid})")

      # Poll until the process exits
      loop do
        unless Harnex.alive_pid?(target_pid)
          # Check for exit status file
          exit_path = File.join(Harnex::STATE_DIR, "exits", "#{@options[:id]}.json")
          if File.exist?(exit_path)
            data = JSON.parse(File.read(exit_path))
            puts JSON.generate(data)
            return data["exit_code"] || 0
          else
            puts JSON.generate(ok: true, id: @options[:id], status: "exited")
            return 0
          end
        end

        if deadline && Time.now >= deadline
          puts JSON.generate(ok: false, id: @options[:id], status: "timeout", pid: target_pid)
          return 124
        end

        sleep POLL_INTERVAL
      end
    end

    private

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: harnex wait [options]"
        opts.on("--id ID", "Session ID to wait for") { |value| @options[:id] = Harnex.normalize_id(Harnex.ensure_option_value!("--id", value)) }
        opts.on("--repo PATH", "Resolve session using PATH's repo root") { |value| @options[:repo_path] = Harnex.ensure_option_value!("--repo", value) }
        opts.on("--timeout SECONDS", Float, "Maximum time to wait") { |value| @options[:timeout] = value }
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
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
        .sort_by { |session| [session["repo_root"].to_s, session["started_at"].to_s, session["id"].to_s] }
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
      columns = ["ID", "CLI", "PID", "PORT", "AGE", "LAST", "STATE"]
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
        "ID" => session["id"].to_s,
        "CLI" => Harnex.session_cli(session).empty? ? "-" : Harnex.session_cli(session),
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
        opts.on("--id ID", "Target a session by ID") { |value| options[:id] = Harnex.normalize_id(Harnex.ensure_option_value!("--id", value)) }
        opts.on("--label ID", "Alias for --id (deprecated)") { |value| options[:id] = Harnex.normalize_id(Harnex.ensure_option_value!("--label", value)) }
        opts.on("--cli CLI", Adapters.supported, "Filter by CLI type (#{Adapters.supported.join(', ')})") { |value| options[:cli] = value }
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
