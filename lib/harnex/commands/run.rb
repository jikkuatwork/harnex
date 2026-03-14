require "json"
require "optparse"
require "shellwords"

module Harnex
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
      harnex_bin = File.expand_path("../../../bin/harnex", __dir__)
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
end
