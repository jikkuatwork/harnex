require "json"
require "optparse"
require "shellwords"

module Harnex
  class Runner
    DEFAULT_TIMEOUT = 5.0
    TELEMETRY_FLAGS = {
      "--project-id" => "project_id",
      "--queue-id" => "queue_id",
      "--entry-id" => "entry_id",
      "--entry-title" => "entry_title",
      "--phase" => "phase",
      "--tier" => "tier",
      "--issue" => "issue",
      "--plan" => "plan",
      "--intent" => "intent",
      "--model" => "model",
      "--effort" => "effort",
      "--parent-dispatch-id" => "parent_dispatch_id",
      "--parent-attempt-id" => "parent_attempt_id",
      "--attempt-kind" => "attempt_kind",
      "--orchestration-run-id" => "orchestration_run_id",
      "--orchestration-generation-id" => "orchestration_generation_id",
      "--orchestration-role" => "orchestration_role",
      "--orchestration-session-id" => "orchestration_session_id",
      "--orchestration-rotation-reason" => "orchestration_rotation_reason"
    }.freeze
    TELEMETRY_KEYS_TO_FLAGS = TELEMETRY_FLAGS.invert.freeze
    TELEMETRY_EQUALS_PREFIXES = TELEMETRY_FLAGS.keys.map { |flag| "#{flag}=" }.freeze

    KNOWN_FLAGS = %w[
      --id --description --detach --tmux --host --port --watch --watch-file
      --stall-after --max-resumes --preset --context --meta --summary-out
      --artifact-report --validation-report --cwd --root --timeout --inbox-ttl
      --require-artifact-report --require-attribution --auto-stop --fast --legacy-pty
      --allow-live-parent --help
    ].concat(TELEMETRY_FLAGS.keys).freeze

    # Attempt kinds that redo the parent's work; dispatching one while the
    # parent is still running duplicates work in the same checkout.
    LIVE_PARENT_GUARDED_KINDS = %w[retry fix fallback superseding].freeze
    VALUE_FLAGS = %w[
      --id --description --host --port --watch --watch-file --stall-after
      --max-resumes --preset --context --meta --summary-out --artifact-report
      --validation-report --cwd --root --timeout --inbox-ttl
    ].concat(TELEMETRY_FLAGS.keys).freeze

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
          --auto-stop        Stop after the first accepted task completion from --context
          --fast             (codex only) Use Codex service_tier="fast".
                             Default Codex runs force service_tier="flex".
          --meta JSON        Attach parsed JSON metadata to the started event
          --summary-out PATH Also mirror the dispatch end record JSONL to PATH
          --artifact-report PATH
                             Worker-written harnex.artifact_report.v1 JSON sidecar to ingest at exit
          --validation-report PATH
                             Alias for --artifact-report; also exposed as HARNEX_VALIDATION_REPORT_PATH
          --require-artifact-report
                             Fail closed unless PATH contains accepted final proof;
                             requires --artifact-report or --validation-report
          --project-id ID    Queue telemetry project id (first-class flags override --meta)
          --queue-id ID      Queue telemetry queue id
          --entry-id ID      Queue telemetry entry id
          --entry-title TEXT Queue telemetry entry title
          --phase TEXT       Queue/work phase telemetry
          --tier TEXT        Queue/work tier telemetry
          --issue ID         Queue/work issue telemetry
          --plan ID          Queue/work plan telemetry
          --intent TEXT      Queue/work intent telemetry
          --model NAME       Requested model metadata (also used for structured dispatch)
          --effort LEVEL     Requested reasoning effort metadata (structured dispatch)
          --parent-dispatch-id ID
                             Parent dispatch id for retry/fix/review/fallback joins
          --parent-attempt-id ID
                             Parent attempt id for retry/fix/review/fallback joins
          --attempt-kind KIND
                             initial, retry, fix, review, fallback, or superseding (default: initial).
                             retry/fallback requires --parent-dispatch-id so the
                             duplicate-dispatch guard can verify the parent
          --allow-live-parent
                             Dispatch even though --parent-dispatch-id names a
                             session that is still running (intentional
                             parallelism, e.g. isolated worktrees)
          --orchestration-run-id ID
                             Logical primary-orchestrator run id for queue rollups
          --orchestration-generation-id ID
                             Primary generation id after rotation/recovery boundaries
          --orchestration-role ROLE
                             primary or worker; defaults to worker in rollups when omitted
          --orchestration-session-id ID
                             External primary session id to preserve in rollups
          --orchestration-rotation-reason TEXT
                             Clean rotation/recovery reason for the generation
          --require-attribution
                             Fail before launch unless project/phase/intent and one work id are present
          --cwd DIR          Run the wrapped agent from DIR and use DIR as the session root
          --root DIR         Override harnex session/root attribution without changing child cwd
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
          --auto-stop requires --context. Structured Codex turns only count as
          accepted completion after activity, Git delta, or accepted sidecar proof.
          --require-artifact-report makes sidecar validation part of the run verdict.
          Explicit --stall-after/--max-resumes values override --preset defaults.
          CLIs with smart prompt detection: #{Adapters.known.join(', ')}
          Any other CLI name is launched with generic wrapping.
          Wrapper options may appear before or after <cli>.

        Common patterns:
          #{program_name} pi --id pi-i-42 --tmux pi-i-42 --context "Read /tmp/task-impl-42.md"
          #{program_name} pi --id pi-i-42 --tmux pi-i-42 --context "Read /tmp/task-impl-42.md" --auto-stop
          #{program_name} pi --id pi-i-42 --watch --preset impl --context "Read /tmp/task-impl-42.md"
          #{program_name} codex --cwd /tmp/public-bundle --id eval-001 --context "Read README.md and write OUTPUT.md" --auto-stop
          #{program_name} pi --id pi-i-52 --artifact-report .harnex/reports/pi-i-52.json --context "Write proof to $HARNEX_ARTIFACT_REPORT_PATH" --auto-stop
          #{program_name} pi --project-id harnex --queue-id queue-005 --entry-id SP-4 --phase implement --intent queue-work --require-attribution --context "Implement SP-4"
          #{program_name} claude --id cl-r-42 --tmux cl-r-42 --description "Review task 42"

        Gotchas:
          Always pair --id and --tmux with the same value for delegated work.
          Passing --tmux without --id creates a random harnex session ID.
          --watch is foreground-only; do not combine it with --tmux or --detach.
          Use -- before child CLI flags when a flag could be parsed by harnex.
          Codex JSON-RPC: pass model as `-c model=NAME`, not `-m NAME`. The
            legacy PTY adapter (--legacy-pty) accepts `-m`.
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
      @launch_cwd = Dir.pwd
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
        telemetry: {},
        require_attribution: false,
        summary_out: nil,
        artifact_report: nil,
        require_artifact_report: false,
        cwd: nil,
        root: nil,
        auto_stop: false,
        allow_live_parent: false,
        detach: false,
        tmux: false,
        tmux_name: nil,
        timeout: DEFAULT_TIMEOUT,
        inbox_ttl: default_inbox_ttl,
        fast: false,
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
      validate_required_artifact_report!
      apply_telemetry_options!
      validate_attempt_metadata!
      validate_orchestration_metadata!
      validate_required_attribution!

      repo_root = resolve_run_root(cli_name, child_args)
      @options[:summary_out] = resolve_summary_out(repo_root)
      @options[:artifact_report] = resolve_artifact_report(repo_root)
      @options[:id] ||= Harnex.generate_id(repo_root)
      validate_unique_id!(repo_root)
      validate_live_parent_guard!(repo_root)
      effective_child_args = apply_context(apply_codex_service_tier(cli_name, child_args))
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
      @options[:telemetry].each do |key, value|
        flag = TELEMETRY_KEYS_TO_FLAGS[key]
        tmux_cmd += [flag, value] if flag && value
      end
      tmux_cmd << "--require-attribution" if @options[:require_attribution]
      tmux_cmd << "--allow-live-parent" if @options[:allow_live_parent]
      tmux_cmd += ["--summary-out", @options[:summary_out]] if @options[:summary_out]
      tmux_cmd += ["--artifact-report", @options[:artifact_report]] if @options[:artifact_report]
      tmux_cmd << "--require-artifact-report" if @options[:require_artifact_report]
      tmux_cmd += ["--cwd", @options[:cwd]] if @options[:cwd]
      tmux_cmd += ["--root", @options[:root]] if @options[:root]
      tmux_cmd += ["--inbox-ttl", @options[:inbox_ttl].to_s]
      tmux_cmd << "--fast" if @options[:fast]
      tmux_cmd += ["--legacy-pty"] if @options[:legacy_pty]
      tmux_cmd += ["--"] + child_args unless child_args.empty?

      window_name = @options[:tmux_name] || @options[:id]
      shell_cmd = tmux_cmd.map { |arg| Shellwords.shellescape(arg) }.join(" ")

      tmux_start_cwd = @options[:cwd] || @launch_cwd
      started =
        if ENV["TMUX"]
          system("tmux", "new-window", "-c", tmux_start_cwd, "-n", window_name, "-d", shell_cmd)
        else
          system("tmux", "new-session", "-c", tmux_start_cwd, "-d", "-s", "harnex", "-n", window_name, shell_cmd)
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

    # Duplicate-dispatch guard (issue #62): a retry/fix/fallback/superseding attempt
    # whose parent dispatch is still running would duplicate work in the same
    # checkout. Explicit --parent-dispatch-id only — the implicit HARNEX_ID
    # lineage of a live spawner must not trip this.
    def validate_live_parent_guard!(repo_root)
      metadata = @options[:meta].is_a?(Hash) ? @options[:meta] : {}
      kind = metadata["attempt_kind"].to_s
      parent_id = metadata["parent_dispatch_id"].to_s.strip

      if %w[retry fallback].include?(kind) && parent_id.empty?
        raise "harnex run: --attempt-kind #{kind} requires --parent-dispatch-id " \
              "so the duplicate-dispatch guard can verify the parent is not still running."
      end

      return if @options[:allow_live_parent]
      return if parent_id.empty?
      return unless LIVE_PARENT_GUARDED_KINDS.include?(kind)

      live = Harnex.active_sessions(repo_root, id: parent_id).first
      return unless live

      raise "harnex run: refusing #{kind} dispatch — parent dispatch #{parent_id.inspect} " \
            "is still running (pid #{live['pid']}, started #{live['started_at']}). " \
            "Wait for it (harnex wait --id #{parent_id} --until done), stop it, " \
            "or pass --allow-live-parent for intentional parallelism."
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
        artifact_report_path: @options[:artifact_report],
        require_artifact_report: @options[:require_artifact_report],
        inbox_ttl: @options[:inbox_ttl],
        auto_stop: @options[:auto_stop],
        launch_cwd: history_cwd,
        child_cwd: session_child_cwd
      )
    end

    def adapter_repo_path(cli_name, child_args)
      Harnex.build_adapter(cli_name, child_args, legacy_pty: @options[:legacy_pty]).infer_repo_path(child_args)
    end

    def resolve_run_root(cli_name, child_args)
      return @options[:root] if @options[:root]
      return @options[:cwd] if @options[:cwd]

      Harnex.resolve_repo_root(adapter_repo_path(cli_name, child_args))
    end

    def history_cwd
      @options[:root] || @options[:cwd] || @launch_cwd
    end

    def session_child_cwd
      return @options[:cwd] if @options[:cwd]
      return @launch_cwd if @options[:root]

      nil
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
        when "--allow-live-parent"
          @options[:allow_live_parent] = true
        when "--require-attribution"
          @options[:require_attribution] = true
        when "--fast"
          @options[:fast] = true
        when "--meta"
          index += 1
          @options[:meta] = parse_meta(required_option_value(arg, argv[index]))
        when /\A--meta=(.+)\z/
          @options[:meta] = parse_meta(required_option_value("--meta", Regexp.last_match(1)))
        when *TELEMETRY_FLAGS.keys
          index += 1
          @options[:telemetry][TELEMETRY_FLAGS.fetch(arg)] = required_option_value(arg, argv[index])
        when telemetry_equals_regex
          flag = "--#{Regexp.last_match(1)}"
          @options[:telemetry][TELEMETRY_FLAGS.fetch(flag)] = required_option_value(flag, Regexp.last_match(2))
        when "--summary-out"
          index += 1
          @options[:summary_out] = required_option_value(arg, argv[index])
        when /\A--summary-out=(.+)\z/
          @options[:summary_out] = required_option_value("--summary-out", Regexp.last_match(1))
        when "--artifact-report", "--validation-report"
          index += 1
          @options[:artifact_report] = required_option_value(arg, argv[index])
        when "--require-artifact-report"
          @options[:require_artifact_report] = true
        when /\A--artifact-report=(.+)\z/
          @options[:artifact_report] = required_option_value("--artifact-report", Regexp.last_match(1))
        when /\A--validation-report=(.+)\z/
          @options[:artifact_report] = required_option_value("--validation-report", Regexp.last_match(1))
        when "--cwd"
          index += 1
          @options[:cwd] = expand_existing_directory(required_option_value(arg, argv[index]), option_name: arg)
        when /\A--cwd=(.+)\z/
          @options[:cwd] = expand_existing_directory(required_option_value("--cwd", Regexp.last_match(1)), option_name: "--cwd")
        when "--root"
          index += 1
          @options[:root] = expand_existing_directory(required_option_value(arg, argv[index]), option_name: arg)
        when /\A--root=(.+)\z/
          @options[:root] = expand_existing_directory(required_option_value("--root", Regexp.last_match(1)), option_name: "--root")
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
          reject_unknown_long_flag!(arg) if unknown_long_flag?(arg)
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

    def telemetry_equals_regex
      @telemetry_equals_regex ||= /\A--(#{TELEMETRY_FLAGS.keys.map { |flag| Regexp.escape(flag.delete_prefix("--")) }.join("|")})=(.+)\z/
    end

    def unknown_long_flag?(arg)
      arg.start_with?("--")
    end

    def reject_unknown_long_flag!(arg)
      flag = arg.split("=", 2).first
      raise OptionParser::InvalidOption,
            "harnex run: unknown flag #{flag}; see harnex run --help"
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
        when "-h", "--help", "--detach", "--tmux", "--auto-stop", "--require-artifact-report", "--require-attribution", "--fast", "--legacy-pty", "--allow-live-parent"
          nil
        when /\A--tmux=/
          nil
        when *VALUE_FLAGS
          index += 1
        when /\A--(?:id|description|host|port|watch|watch-file|stall-after|max-resumes|context|meta|summary-out|artifact-report|validation-report|cwd|root|timeout|inbox-ttl)=/
          nil
        when telemetry_equals_regex
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
          "--artifact-report=", "--validation-report=", "--cwd=", "--root=", "--timeout=", "--inbox-ttl=",
          *TELEMETRY_EQUALS_PREFIXES
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

    def validate_required_artifact_report!
      return unless @options[:require_artifact_report]
      return unless @options[:artifact_report].to_s.strip.empty?

      raise OptionParser::InvalidOption,
            "harnex run: --require-artifact-report requires --artifact-report PATH"
    end

    def apply_telemetry_options!
      explicit = @options[:telemetry]
      return if explicit.empty? && @options[:meta].is_a?(Hash)
      return if explicit.empty?

      @options[:meta] = (@options[:meta].is_a?(Hash) ? @options[:meta].dup : {}).merge(explicit)
    end

    def validate_attempt_metadata!
      metadata = @options[:meta].is_a?(Hash) ? @options[:meta] : {}
      kind = metadata["attempt_kind"].to_s
      return if kind.empty? || Session::ATTEMPT_KINDS.include?(kind)

      raise OptionParser::InvalidOption,
            "harnex run: --attempt-kind must be one of #{Session::ATTEMPT_KINDS.join(', ')}"
    end

    def validate_orchestration_metadata!
      metadata = @options[:meta].is_a?(Hash) ? @options[:meta] : {}
      role = metadata["orchestration_role"].to_s
      return if role.empty? || Orchestration::ROLES.include?(role)

      raise OptionParser::InvalidOption,
            "harnex run: --orchestration-role must be one of #{Orchestration::ROLES.join(', ')}"
    end

    def validate_required_attribution!
      return unless @options[:require_attribution]

      metadata = @options[:meta].is_a?(Hash) ? @options[:meta] : {}
      missing = %w[project_id phase intent].select { |key| blank_value?(metadata[key]) }
      unless %w[queue_id entry_id issue plan].any? { |key| !blank_value?(metadata[key]) }
        missing << "one of queue_id/entry_id/issue/plan"
      end
      return if missing.empty?

      raise OptionParser::InvalidOption,
            "harnex run: --require-attribution missing #{missing.join(', ')}"
    end

    def blank_value?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def apply_codex_service_tier(cli_name, child_args)
      return child_args unless cli_name.to_s == "codex"
      return child_args if child_service_tier_config?(child_args)

      child_args + ["-c", "service_tier=\"#{@options[:fast] ? 'fast' : 'flex'}\""]
    end

    def child_service_tier_config?(child_args)
      child_args.each_with_index.any? do |arg, index|
        text = arg.to_s
        text.start_with?("service_tier=") ||
          text.start_with?("service_tier.") ||
          text == "-c" && child_args[index + 1].to_s.start_with?("service_tier") ||
          text == "--config" && child_args[index + 1].to_s.start_with?("service_tier") ||
          text.start_with?("-cservice_tier") ||
          text.start_with?("--config=service_tier")
      end
    end

    def parse_non_negative_integer(value, option_name:)
      integer = Integer(value)
      raise OptionParser::InvalidArgument, "#{option_name} must be 0 or greater" if integer.negative?

      integer
    rescue ArgumentError
      raise OptionParser::InvalidArgument, "#{option_name} must be an integer"
    end

    def expand_existing_directory(value, option_name:)
      path = File.expand_path(value.to_s, @launch_cwd)
      return path if File.directory?(path)

      raise OptionParser::InvalidArgument, "#{option_name} must be an existing directory: #{value}"
    end

    def parse_meta(value)
      parsed = JSON.parse(value)
      return parsed if parsed.is_a?(Hash)

      raise OptionParser::InvalidOption, "--meta must be a JSON object"
    rescue JSON::ParserError => e
      raise OptionParser::InvalidOption, "--meta must be valid JSON: #{e.message}"
    end

    # Explicit-only mirror: the tracked dispatch stream is the canonical
    # destination; --summary-out just duplicates the end record elsewhere.
    def resolve_summary_out(repo_root)
      configured = @options[:summary_out]
      return nil if configured.nil?

      File.expand_path(configured, repo_root)
    end

    def resolve_artifact_report(repo_root)
      configured = @options[:artifact_report]
      return nil if configured.nil?

      path = File.expand_path(configured, repo_root)
      FileUtils.mkdir_p(File.dirname(path))
      path
    end

    def default_inbox_ttl
      value = ENV["HARNEX_INBOX_TTL"]
      return Inbox::DEFAULT_TTL.to_f if value.nil? || value.strip.empty?

      Float(value)
    end
  end
end
