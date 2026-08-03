require "json"
require "optparse"

module Harnex
  class Doctor
    MIN_CODEX_VERSION = Gem::Version.new("0.128.0")

    def self.usage
      <<~TEXT
        Usage: harnex doctor [--sweep] [--prune [--dry-run]]

        Runs preflight checks for harnex's adapter dependencies.
        Currently verifies that Codex CLI is installed and at version
        >= #{MIN_CODEX_VERSION} (required for the JSON-RPC `app-server`
        adapter).

        Options:
          --sweep      Include a read-only report of harnex/tmux session drift
          --prune      Apply bounded harnex events/output/receipt retention pruning
          --dry-run    Preview --prune candidates without deleting
          -h, --help   Show this help

        Common patterns:
          harnex doctor
          harnex doctor --sweep
          harnex doctor --prune --dry-run
          harnex doctor --prune
          harnex doctor --help

        Gotchas:
          doctor validates local adapter prerequisites; it does not start sessions.
          --sweep is diagnostic only; it does not stop sessions or remove files.
          --dry-run must be paired with --prune.
          Run it after installing or upgrading Codex CLI.
      TEXT
    end

    def initialize(argv = [])
      @argv = argv.dup
      @options = {
        sweep: false,
        prune: false,
        dry_run: false,
        help: false
      }
    end

    def run
      parser.parse!(@argv)
      validate_options!
      if @options[:help]
        puts self.class.usage
        return 0
      end

      checks = [check_codex]
      retention = retention_payload
      summary = {
        ok: checks.all? { |c| c[:ok] } && retention.fetch(:ok, true),
        checks: checks,
        retention: retention
      }
      summary[:sweep] = sweep_payload if @options[:sweep]
      puts JSON.generate(summary)
      summary[:ok] ? 0 : 1
    end

    private

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: harnex doctor [--sweep] [--prune [--dry-run]]"
        opts.on("--sweep", "Include read-only session drift diagnostics") { @options[:sweep] = true }
        opts.on("--prune", "Apply retention pruning") { @options[:prune] = true }
        opts.on("--dry-run", "Preview --prune candidates without deleting") { @options[:dry_run] = true }
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end

    def validate_options!
      return if @options[:help]
      return unless @options[:dry_run] && !@options[:prune]

      raise OptionParser::InvalidOption, "--dry-run requires --prune"
    end

    def retention_payload
      repo_root = Harnex.resolve_repo_root(Dir.pwd)
      if @options[:prune]
        Harnex::Retention.prune(
          repo_root: repo_root,
          dry_run: @options[:dry_run],
          force: true
        )
      else
        Harnex::Retention.status(repo_root: repo_root)
      end
    rescue Harnex::Config::ConfigError => e
      { ok: false, error: e.message }
    end

    def check_codex
      result = { name: "codex", required: ">= #{MIN_CODEX_VERSION}" }

      version_output, status = capture("codex --version")
      if status.nil?
        return result.merge(ok: false, error: "codex CLI not found on PATH")
      end
      unless status.success?
        return result.merge(ok: false, error: "codex --version failed: #{version_output.strip}")
      end

      version = parse_version(version_output)
      if version.nil?
        return result.merge(ok: false, found: version_output.strip, error: "could not parse codex version output")
      end

      if version < MIN_CODEX_VERSION
        return result.merge(ok: false, found: version.to_s,
                            error: "codex #{version} < required #{MIN_CODEX_VERSION}; upgrade with `npm i -g @openai/codex` or your platform package manager")
      end

      result.merge(ok: true, found: version.to_s)
    end

    def capture(command)
      output = `#{command} 2>&1`
      [output, $?]
    rescue StandardError => e
      [e.message, nil]
    end

    def sweep_payload
      active, stale = read_session_registry
      tmux_windows = read_tmux_windows
      live_ids = active.map { |session| session["id"].to_s }.to_set

      {
        harnex_sessions: active,
        tmux_windows_cx: tmux_windows,
        orphan_tmux: tmux_windows.reject { |window| live_ids.include?(window[:session]) || live_ids.include?(window[:window]) },
        stale_pid_files: stale
      }
    end

    def read_session_registry
      return [[], []] unless Dir.exist?(Harnex::SESSIONS_DIR)

      active = []
      stale = []

      Dir.glob(File.join(Harnex::SESSIONS_DIR, "*.json")).sort.each do |path|
        data = JSON.parse(File.read(path)).merge("registry_path" => path)
        if data["pid"] && Harnex.alive_pid?(data["pid"])
          active << data
        else
          stale << stale_session_files(data, path)
        end
      rescue JSON::ParserError
        stale << { registry_path: path, error: "invalid_json" }
      end

      [active.sort_by { |session| [session["repo_root"].to_s, session["started_at"].to_s, session["id"].to_s] }.reverse, stale]
    end

    def stale_session_files(data, registry_path)
      repo_root = data["repo_root"].to_s
      id = data["id"].to_s
      slug = repo_root.empty? || id.empty? ? nil : Harnex.session_file_slug(repo_root, id)
      output_log_path = slug ? File.join(Harnex::STATE_DIR, "output", "#{slug}.log") : nil
      events_log_path = slug ? File.join(Harnex::STATE_DIR, "events", "#{slug}.jsonl") : nil

      {
        id: id.empty? ? nil : id,
        pid: data["pid"],
        repo_root: repo_root.empty? ? nil : repo_root,
        registry_path: registry_path,
        output_log_path: file_or_nil(output_log_path),
        events_log_path: file_or_nil(events_log_path)
      }
    end

    def read_tmux_windows
      output, status = capture("tmux list-windows -a -F '\#{session_name}\t\#{window_name}\t\#{pane_pid}'")
      return [] unless status&.success?

      output.lines.filter_map do |line|
        session, window, pid = line.chomp.split("\t", 3)
        next unless session.to_s.start_with?("cx-") || window.to_s.start_with?("cx-")

        { session: session, window: window, pid: integer_or_nil(pid) }
      end
    end

    def file_or_nil(path)
      path if path && File.exist?(path)
    end

    def integer_or_nil(value)
      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def parse_version(text)
      match = text.match(/(\d+\.\d+\.\d+)/)
      match ? Gem::Version.new(match[1]) : nil
    end
  end
end
