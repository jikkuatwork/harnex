require "json"
require "optparse"
require "shellwords"

module Harnex
  class Runner
    DEFAULT_TIMEOUT = 5.0
    KNOWN_FLAGS = %w[
      --id --description --detach --tmux --host --port --watch --watch-file
      --stall-after --max-resumes --preset --context --meta --summary-out
      --timeout --inbox-ttl --auto-stop --legacy-pty --help
    ].freeze
    VALUE_FLAGS = %w[
      --id --description --host --port --watch --watch-file --stall-after
      --max-resumes --preset --context --meta --summary-out --timeout --inbox-ttl
    ].freeze

    def self.usage(program_name = "harnex run")
      <<~TEXT
        Usage: #{program_name} <cli> [options] [--] [cli-args...]

        Options:
          --id ID            Session identifier (default: random two-word ID)
          --description TEXT Short description of what this session is doing
          --detach           Start session in background and return JSON on stdout
          --tmux [NAME]      Run in a tmux window (implies --detach)
          --host HOST        Bind host for the local API (default: #{DEFAULT_HOST})
          --port PORT        Force a specific local API port
          --watch            Enable blocking babysitter mode (foreground only)
          --stall-after DUR  Force-resume threshold (default: #{RunWatcher::DEFAULT_STALL_AFTER_S.to_i}s)
          --max-resumes N    Max forced resumes before escalation (default: #{RunWatcher::DEFAULT_MAX_RESUMES})
          --preset NAME      Watch preset: impl, plan, gate (requires --watch)
          --watch-file PATH  Auto-send a file-change hook on modification
          --context TEXT     Inject as the initial prompt (prepends session header)
          --auto-stop        Stop after the first task completion from --context
          --meta JSON        Attach parsed JSON metadata to the started event
          --summary-out PATH Append dispatch telemetry summary JSONL to PATH
          --timeout SECS     Max seconds to wait for detached registration (default: #{DEFAULT_TIMEOUT})
          --inbox-ttl SECS   Expire queued inbox messages after SECS (default: #{Inbox::DEFAULT_TTL})
          --legacy-pty       (codex only) Use the legacy PTY adapter instead of
                             the JSON-RPC `app-server` adapter. Long-term
                             supported fallback for interactive/TUI use; JSON-RPC
                             remains the default for autonomous dispatches.
          -h, --help         Show this help

        Notes:
          Compatibility: `--watch PATH` and `--watch=PATH` still configure file-hook mode.
          Bare `--watch` enables the babysitter.
          --auto-stop requires --context and fires once after the first completion.
          Explicit --stall-after/--max-resumes values override --preset defaults.
          CLIs with smart prompt detection: #{Adapters.known.join(', ')}
          Any other CLI name is launched with generic wrapping.
          Wrapper options may appear before or after <cli>.

        Common patterns:
          #{program_name} codex --id cx-i-42 --tmux cx-i-42 --context "Read /tmp/task-impl-42.md"
          #{program_name} codex --id cx-i-42 --tmux cx-i-42 --context "Read /tmp/task-impl-42.md" --auto-stop
          #{program_name} codex --id cx-i-42 --watch --preset impl --context "Read /tmp/task-impl-42.md"
          #{program_name} claude --id cl-r-42 --tmux cl-r-42 --description "Review task 42"

        Gotchas:
          Always pair --id and --tmux with the same value for delegated work.
          Passing --tmux without --id creates a random harnex session ID.
          --watch is foreground-only; do not combine it with --tmux or --detach.
          Use -- before child CLI flags when a flag could be parsed by harnex.
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {
        id: nil,
        description: nil,
        host: DEFAULT_HOST,
        port: nil,
        watch_enabled: false,
        stall_after_s: RunWatcher::DEFAULT_STALL_AFTER_S,
        stall_after_explicit: false,
        max_resumes: RunWatcher::DEFAULT_MAX_RESUMES,
        max_resumes_explicit: false,
        preset: nil,
        watch: nil,
        context: nil,
        meta: nil,
        summary_out: nil,
        auto_stop: false,
        detach: false,
        tmux: false,
        tmux_name: nil,
        timeout: DEFAULT_TIMEOUT,
        inbox_ttl: default_inbox_ttl,
        legacy_pty: false,
        help: false
      }
    end

    def run
      cli_name, child_args = extract_wrapper_options(@argv)
      if @options[:help]
        puts self.class.usage
        return 0
      end

      raise OptionParser::MissingArgument, "cli" if cli_name.nil?
      validate_auto_stop_context!

      repo_root = Harnex.resolve_repo_root(adapter_repo_path(cli_name, child_args))
      @options[:summary_out] = resolve_summary_out(repo_root)
      @options[:id] ||= Harnex.generate_id(repo_root)
      validate_unique_id!(repo_root)
      effective_child_args = apply_context(child_args)
      adapter = Harnex.build_adapter(cli_name, effective_child_args, legacy_pty: @options[:legacy_pty])
      @options[:detach] = true if @options[:tmux]
      validate_watch_mode!
      resolve_watch_preset!

      if @options[:watch_enabled]
        run_watch_mode(adapter, repo_root)
      elsif @options[:detach]
        run_detached(adapter, cli_name, child_args, repo_root)
      else
        run_foreground(adapter, repo_root)
      end
    end

    def run_foreground(adapter, repo_root)
      session = build_session(adapter, repo_root)
      session.validate_binary!
      warn("harnex: session #{session.id} on #{session.host}:#{session.port}")
      session.run(validate_binary: false)
    end

    def run_detached(adapter, cli_name, child_args, repo_root)
      Session.validate_binary!(adapter.build_command)

      if @options[:tmux]
        run_in_tmux(cli_name, child_args, repo_root)
      else
        result = run_headless(adapter, repo_root)
        result[:exit_code]
      end
    end

    def run_watch_mode(adapter, repo_root)
      Session.validate_binary!(adapter.build_command)

      result = run_headless(adapter, repo_root, emit_payload: false)
      return result[:exit_code] unless result[:ok]

      RunWatcher.new(
        id: @options[:id],
        repo_root: repo_root,
        stall_after_s: @options[:stall_after_s],
        max_resumes: @options[:max_resumes]
      ).run
    end

    def run_in_tmux(cli_name, child_args, repo_root)
      harnex_bin = File.expand_path("../../../bin/harnex", __dir__)
      tmux_cmd = [harnex_bin, "run", cli_name]
      tmux_cmd += ["--id", @options[:id]]
      tmux_cmd += ["--description", @options[:description]] if @options[:description]
      tmux_cmd += ["--host", @options[:host]]
      tmux_cmd += ["--port", @options[:port].to_s] if @options[:port]
      tmux_cmd += ["--watch-file", @options[:watch]] if @options[:watch]
      tmux_cmd += ["--context", @options[:context]] if @options[:context]
      tmux_cmd << "--auto-stop" if @options[:auto_stop]
      tmux_cmd += ["--meta", JSON.generate(@options[:meta])] if @options[:meta]
      tmux_cmd += ["--summary-out", @options[:summary_out]] if @options[:summary_out]
      tmux_cmd += ["--inbox-ttl", @options[:inbox_ttl].to_s]
      tmux_cmd += ["--legacy-pty"] if @options[:legacy_pty]
      tmux_cmd += ["--"] + child_args unless child_args.empty?

      window_name = @options[:tmux_name] || @options[:id]
      shell_cmd = tmux_cmd.map { |arg| Shellwords.shellescape(arg) }.join(" ")

      started =
        if ENV["TMUX"]
          system("tmux", "new-window", "-n", window_name, "-d", shell_cmd)
        else
          system("tmux", "new-session", "-d", "-s", "harnex", "-n", window_name, shell_cmd)
        end

      raise "tmux failed to start #{cli_name.inspect}" unless started

      registry = wait_for_registration(repo_root)
      return registration_timeout(@options[:id]) unless registry
      registry = annotate_tmux_registry(registry)

      payload = {
        ok: true,
        id: @options[:id],
        cli: cli_name,
        pid: registry["pid"],
        port: registry["port"],
        mode: "tmux",
        window: window_name,
        output_log_path: Harnex.output_log_path(repo_root, @options[:id])
      }
      payload[:description] = @options[:description] if @options[:description]
      puts JSON.generate(payload)
      0
    end

    def run_headless(adapter, repo_root, emit_payload: true)
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

        session = build_session(adapter, repo_root)
        exit_code = session.run(validate_binary: false)
        exit(exit_code || 1)
      end

      Process.detach(child_pid)

      registry = wait_for_registration(repo_root)
      return { ok: false, exit_code: registration_timeout(@options[:id]) } unless registry

      payload = {
        ok: true,
        id: @options[:id],
        cli: adapter.key,
        pid: registry["pid"],
        port: registry["port"],
        mode: "headless",
        log: log_path,
        output_log_path: Harnex.output_log_path(repo_root, @options[:id])
      }
      payload[:description] = @options[:description] if @options[:description]
      puts JSON.generate(payload) if emit_payload
      { ok: true, exit_code: 0, registry: registry, payload: payload }
    end

    private

    def validate_watch_mode!
      return unless @options[:watch_enabled]
      return unless @options[:detach]

      raise OptionParser::InvalidOption, "--watch is only supported in foreground mode"
    end

    def validate_unique_id!(repo_root)
      existing = Harnex.read_registry(repo_root, @options[:id])
      return unless existing

      raise "harnex run: session #{@options[:id].inspect} is already active " \
            "(pid #{existing['pid']}, port #{existing['port']}). " \
            "Use a different --id or stop the existing session first."
    end

    def build_session(adapter, repo_root)
      watch = Harnex.build_watch_config(@options[:watch], repo_root)
      Session.new(
        adapter: adapter,
        command: adapter.build_command,
        repo_root: repo_root,
        host: @options[:host],
        port: @options[:port],
        id: @options[:id],
        watch: watch,
        description: @options[:description],
        meta: @options[:meta],
        summary_out: @options[:summary_out],
        inbox_ttl: @options[:inbox_ttl],
        auto_stop: @options[:auto_stop]
      )
    end

    def adapter_repo_path(cli_name, child_args)
      Harnex.build_adapter(cli_name, child_args, legacy_pty: @options[:legacy_pty]).infer_repo_path(child_args)
    end

    def apply_context(child_args)
      return child_args unless @options[:context]

      context = "[harnex session id=#{@options[:id]}] #{@options[:context]}"
      child_args + [context]
    end

    def wait_for_registration(repo_root)
      deadline = Time.now + @options[:timeout]
      loop do
        registry = Harnex.read_registry(repo_root, @options[:id])
        return registry if registry
        return nil if Time.now >= deadline

        sleep 0.1
      end
    end

    def annotate_tmux_registry(registry)
      discovery = Harnex.tmux_pane_for_pid(registry["pid"])
      return registry unless discovery

      updated = registry.dup
      updated["tmux_target"] = discovery.fetch(:target)
      updated["tmux_session"] = discovery.fetch(:session_name)
      updated["tmux_window"] = discovery.fetch(:window_name)

      path = registry["registry_path"].to_s
      if !path.empty? && File.exist?(path)
        persisted = JSON.parse(File.read(path))
        Harnex.write_registry(path, persisted.merge(updated))
      end

      updated
    rescue JSON::ParserError
      registry
    end

    def registration_timeout(id)
      warn("harnex: detached session #{id} did not register within #{@options[:timeout]}s")
      124
    end

    def extract_wrapper_options(argv)
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
        when "--id"
          index += 1
          @options[:id] = Harnex.normalize_id(required_option_value(arg, argv[index]))
        when /\A--id=(.+)\z/
          @options[:id] = Harnex.normalize_id(required_option_value("--id", Regexp.last_match(1)))
        when "--description"
          index += 1
          @options[:description] = required_option_value(arg, argv[index])
        when /\A--description=(.+)\z/
          @options[:description] = required_option_value("--description", Regexp.last_match(1))
        when "--detach"
          @options[:detach] = true
        when "--tmux"
          @options[:tmux] = true
          if tmux_name_arg?(argv, index, cli_name)
            index += 1
            @options[:tmux_name] = argv[index]
          end
        when /\A--tmux=(.+)\z/
          @options[:tmux] = true
          @options[:tmux_name] = Regexp.last_match(1)
        when "--host"
          index += 1
          @options[:host] = required_option_value(arg, argv[index])
        when /\A--host=(.+)\z/
          @options[:host] = required_option_value("--host", Regexp.last_match(1))
        when "--port"
          index += 1
          @options[:port] = Integer(required_option_value(arg, argv[index]))
        when /\A--port=(.+)\z/
          @options[:port] = Integer(required_option_value("--port", Regexp.last_match(1)))
        when "--watch"
          value = argv[index + 1]
          if value.nil? || value == "--" || wrapper_option_token?(value)
            @options[:watch_enabled] = true
          else
            index += 1
            @options[:watch] = required_option_value(arg, argv[index])
          end
        when /\A--watch=(.+)\z/
          @options[:watch] = required_option_value("--watch", Regexp.last_match(1))
        when "--watch-file"
          index += 1
          @options[:watch] = required_option_value(arg, argv[index])
        when /\A--watch-file=(.+)\z/
          @options[:watch] = required_option_value("--watch-file", Regexp.last_match(1))
        when "--stall-after"
          index += 1
          @options[:stall_after_s] = Harnex.parse_duration_seconds(
            required_option_value(arg, argv[index]),
            option_name: "--stall-after"
          )
          @options[:stall_after_explicit] = true
        when /\A--stall-after=(.+)\z/
          @options[:stall_after_s] = Harnex.parse_duration_seconds(
            required_option_value("--stall-after", Regexp.last_match(1)),
            option_name: "--stall-after"
          )
          @options[:stall_after_explicit] = true
        when "--max-resumes"
          index += 1
          @options[:max_resumes] = parse_non_negative_integer(
            required_option_value(arg, argv[index]),
            option_name: "--max-resumes"
          )
          @options[:max_resumes_explicit] = true
        when /\A--max-resumes=(.+)\z/
          @options[:max_resumes] = parse_non_negative_integer(
            required_option_value("--max-resumes", Regexp.last_match(1)),
            option_name: "--max-resumes"
          )
          @options[:max_resumes_explicit] = true
        when "--preset"
          index += 1
          @options[:preset] = required_option_value(arg, argv[index])
        when /\A--preset=(.+)\z/
          @options[:preset] = required_option_value("--preset", Regexp.last_match(1))
        when "--context"
          index += 1
          @options[:context] = required_option_value(arg, argv[index])
        when /\A--context=(.+)\z/
          @options[:context] = required_option_value("--context", Regexp.last_match(1))
        when "--auto-stop"
          @options[:auto_stop] = true
        when "--meta"
          index += 1
          @options[:meta] = parse_meta(required_option_value(arg, argv[index]))
        when /\A--meta=(.+)\z/
          @options[:meta] = parse_meta(required_option_value("--meta", Regexp.last_match(1)))
        when "--summary-out"
          index += 1
          @options[:summary_out] = required_option_value(arg, argv[index])
        when /\A--summary-out=(.+)\z/
          @options[:summary_out] = required_option_value("--summary-out", Regexp.last_match(1))
        when "--timeout"
          index += 1
          @options[:timeout] = Float(required_option_value(arg, argv[index]))
        when /\A--timeout=(.+)\z/
          @options[:timeout] = Float(required_option_value("--timeout", Regexp.last_match(1)))
        when "--inbox-ttl"
          index += 1
          @options[:inbox_ttl] = Float(required_option_value(arg, argv[index]))
        when /\A--inbox-ttl=(.+)\z/
          @options[:inbox_ttl] = Float(required_option_value("--inbox-ttl", Regexp.last_match(1)))
        when "--legacy-pty"
          @options[:legacy_pty] = true
        else
          if cli_name.nil?
            cli_name = arg
          else
            forwarded << arg
          end
        end
        index += 1
      end

      [cli_name, forwarded]
    end

    def required_option_value(option_name, value)
      raise OptionParser::MissingArgument, option_name if value.nil?
      raise OptionParser::MissingArgument, option_name if value.match?(/\A-[A-Za-z]/)
      return value unless value.start_with?("--")

      flag = value.split("=", 2).first
      raise OptionParser::MissingArgument, option_name if KNOWN_FLAGS.include?(flag)

      value
    end

    def tmux_name_arg?(argv, index, cli_name)
      value = argv[index + 1]
      return false if value.nil? || value == "--" || wrapper_option_token?(value)
      return false if value.start_with?("--")
      return true if cli_name

      cli_candidate_after?(argv, index + 2)
    end

    def cli_candidate_after?(argv, index)
      while index < argv.length
        arg = argv[index]
        case arg
        when "--"
          return false
        when "-h", "--help", "--detach", "--tmux", "--auto-stop", "--legacy-pty"
          nil
        when /\A--tmux=/
          nil
        when *VALUE_FLAGS
          index += 1
        when /\A--(?:id|description|host|port|watch|watch-file|stall-after|max-resumes|context|meta|summary-out|timeout|inbox-ttl)=/
          nil
        when /\A--preset=/
          nil
        else
          return true
        end
        index += 1
      end

      false
    end

    def wrapper_option_token?(arg)
      KNOWN_FLAGS.include?(arg) ||
        arg == "-h" ||
        arg.start_with?(
          "--id=", "--description=", "--tmux=", "--host=", "--port=", "--watch=", "--watch-file=",
          "--stall-after=", "--max-resumes=", "--preset=", "--context=", "--meta=", "--summary-out=",
          "--timeout=", "--inbox-ttl="
        )
    end

    def resolve_watch_preset!
      preset_name = @options[:preset]
      return if preset_name.nil?

      unless @options[:watch_enabled]
        raise "harnex run: --preset requires --watch"
      end

      preset = WatchPresets.fetch(preset_name)
      unless preset
        valid = WatchPresets.valid_names.join(", ")
        raise "harnex run: unknown --preset #{preset_name.inspect} (valid: #{valid})"
      end

      @options[:stall_after_s] = preset[:stall_after_s] unless @options[:stall_after_explicit]
      @options[:max_resumes] = preset[:max_resumes] unless @options[:max_resumes_explicit]
    end

    def validate_auto_stop_context!
      return unless @options[:auto_stop]
      return if @options[:context]

      raise OptionParser::InvalidOption, "harnex run: --auto-stop requires --context"
    end

    def parse_non_negative_integer(value, option_name:)
      integer = Integer(value)
      raise OptionParser::InvalidArgument, "#{option_name} must be 0 or greater" if integer.negative?

      integer
    rescue ArgumentError
      raise OptionParser::InvalidArgument, "#{option_name} must be an integer"
    end

    def parse_meta(value)
      parsed = JSON.parse(value)
      return parsed if parsed.is_a?(Hash)

      raise OptionParser::InvalidOption, "--meta must be a JSON object"
    rescue JSON::ParserError => e
      raise OptionParser::InvalidOption, "--meta must be valid JSON: #{e.message}"
    end

    def resolve_summary_out(repo_root)
      configured = @options[:summary_out]
      return Harnex.default_summary_out_path(repo_root) if configured.nil?

      File.expand_path(configured, repo_root)
    end

    def default_inbox_ttl
      value = ENV["HARNEX_INBOX_TTL"]
      return Inbox::DEFAULT_TTL.to_f if value.nil? || value.strip.empty?

      Float(value)
    end
  end
end
