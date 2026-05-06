require "json"
require "optparse"
require "open3"
require "time"

module Harnex
  class Pane
    FOLLOW_INTERVAL = 1.0

    def self.usage(program_name = "harnex pane")
      <<~TEXT
        Usage: #{program_name} [options]

        Options:
          --id ID       Session ID to inspect (required)
          --repo PATH   Resolve using PATH's repo root (default: current repo)
          --cli CLI     Filter the active session by CLI
          --lines N     Capture the last N lines instead of the full pane
          --follow      Refresh the pane snapshot every second until the session exits
          --interval N  Refresh interval in seconds for --follow (default: #{FOLLOW_INTERVAL.to_i})
          --json        Output JSON with capture metadata
          -h, --help    Show this help

        Common patterns:
          #{program_name} --id cx-i-42 --lines 40
          #{program_name} --id cx-i-42 --lines 40 --json
          #{program_name} --id cx-i-42 --follow --interval 2

        Gotchas:
          pane requires a tmux-backed session.
          Use --repo when the same ID exists in multiple repos or worktrees.
          Do not use pane state alone as completion proof; verify artifacts/tests.
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {
        id: nil,
        repo_path: Dir.pwd,
        repo_explicit: false,
        cli: nil,
        lines: nil,
        follow: false,
        interval: FOLLOW_INTERVAL,
        json: false,
        help: false
      }
    end

    def run
      parser.parse!(@argv)
      if @options[:help]
        puts self.class.usage
        return 0
      end

      raise "--id is required for harnex pane" unless @options[:id]
      if @options[:lines] && @options[:lines] < 1
        raise OptionParser::InvalidArgument, "--lines must be >= 1"
      end

      session = resolve_session
      return 1 unless session

      return 1 unless tmux_available?

      target = resolve_tmux_target(session)
      return 1 unless target
      return 1 unless tmux_target_exists?(session, target)

      if @options[:follow]
        follow(session, target)
      else
        text = capture(target)
        return 1 unless text

        emit_output(session.fetch("id"), text)
      end
      0
    end

    private

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: harnex pane [options]"
        opts.on("--id ID", "Session ID to inspect") { |value| @options[:id] = Harnex.normalize_id(value) }
        opts.on("--repo PATH", "Resolve using PATH's repo root") do |value|
          @options[:repo_path] = value
          @options[:repo_explicit] = true
        end
        opts.on("--cli CLI", "Filter the active session by CLI") { |value| @options[:cli] = value }
        opts.on("--lines N", Integer, "Capture the last N lines instead of the full pane") { |value| @options[:lines] = value }
        opts.on("--follow", "Refresh the pane snapshot until the session exits") { @options[:follow] = true }
        opts.on("--interval N", Float, "Refresh interval in seconds for --follow") { |value| @options[:interval] = value }
        opts.on("--json", "Output JSON with capture metadata") { @options[:json] = true }
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end

    def resolve_session
      repo_root = Harnex.resolve_repo_root(@options[:repo_path])
      session = Harnex.read_registry(repo_root, @options[:id], cli: @options[:cli])
      return session if session

      unless @options[:repo_explicit]
        candidates = Harnex.active_sessions(nil, id: @options[:id], cli: @options[:cli])
        return candidates.first if candidates.length == 1

        if candidates.length > 1
          repos = candidates.map { |candidate| candidate["repo_root"].to_s }.uniq.sort
          warn("harnex pane: multiple active sessions found with id #{@options[:id].inspect}; use --repo to disambiguate: #{repos.join(', ')}")
          return nil
        end
      end

      if cli_filter_mismatch?(repo_root)
        warn("harnex pane: no active session found with id #{@options[:id].inspect} and cli #{@options[:cli].inspect}")
      else
        warn("harnex pane: no active session found with id #{@options[:id].inspect} for #{repo_root}")
      end
      nil
    end

    def cli_filter_mismatch?(repo_root)
      return false unless @options[:cli]

      session = Harnex.read_registry(repo_root, @options[:id])
      return false unless session

      Harnex.cli_key(Harnex.session_cli(session)) != Harnex.cli_key(@options[:cli])
    end

    def resolve_tmux_target(session)
      target = session["tmux_target"].to_s.strip
      return target unless target.empty?

      discovery = Harnex.tmux_pane_for_pid(session["pid"])
      if discovery
        persist_tmux_metadata(session, discovery)
        return discovery.fetch(:target)
      end

      tmux_session = session["tmux_session"].to_s.strip
      tmux_window = session["tmux_window"].to_s.strip
      unless tmux_session.empty? || tmux_window.empty?
        return "#{tmux_session}:#{tmux_window}"
      end

      warn("harnex pane: session #{session.fetch('id').inspect} is not tmux-backed or the tmux pane could not be located")
      nil
    end

    def persist_tmux_metadata(session, discovery)
      session["tmux_target"] = discovery.fetch(:target)
      session["tmux_session"] = discovery.fetch(:session_name)
      session["tmux_window"] = discovery.fetch(:window_name)

      path = session["registry_path"].to_s
      return if path.empty? || !File.exist?(path)

      payload = JSON.parse(File.read(path))
      payload["tmux_target"] = session["tmux_target"]
      payload["tmux_session"] = session["tmux_session"]
      payload["tmux_window"] = session["tmux_window"]
      Harnex.write_registry(path, payload)
    rescue JSON::ParserError
      nil
    end

    def tmux_available?
      return true if system("tmux", "-V", out: File::NULL, err: File::NULL)

      warn("harnex pane: tmux is not installed or not available in PATH")
      false
    rescue Errno::ENOENT
      warn("harnex pane: tmux is not installed or not available in PATH")
      false
    end

    def tmux_target_exists?(session, target)
      return true if system("tmux", "has-session", "-t", target, out: File::NULL, err: File::NULL)

      warn("harnex pane: session #{session.fetch('id').inspect} is not tmux-backed or the tmux target #{target.inspect} no longer exists")
      false
    rescue Errno::ENOENT
      warn("harnex pane: tmux is not installed or not available in PATH")
      false
    end

    def follow(session, target)
      pid = session["pid"].to_i
      last_text = nil

      loop do
        text = capture(target)
        break unless text

        if text != last_text
          clear_screen
          if @options[:json]
            emit_output(session.fetch("id"), text)
          else
            $stdout.write(text)
            $stdout.flush
          end
          last_text = text
        end

        break unless Harnex.alive_pid?(pid)

        sleep @options[:interval]
      end
    end

    def clear_screen
      $stdout.write("\e[H\e[2J")
      $stdout.flush
    end

    def capture(target)
      stdout, stderr, status = capture_command(capture_command_args(target))
      return stdout if status.success?

      message = stderr.to_s.strip
      message = "tmux capture-pane failed" if message.empty?
      warn("harnex pane: #{message}")
      nil
    rescue Errno::ENOENT
      warn("harnex pane: tmux is not installed or not available in PATH")
      nil
    end

    def capture_command_args(target)
      command = ["tmux", "capture-pane", "-t", target, "-p"]
      command += ["-S", "-#{@options[:lines]}"] if @options[:lines]
      command
    end

    def capture_command(command)
      Open3.capture3(*command)
    end

    def emit_output(id, text)
      if @options[:json]
        puts JSON.generate({
          ok: true,
          id: id,
          captured_at: Time.now.iso8601,
          lines: @options[:lines],
          text: text
        })
        return
      end

      $stdout.write(text)
      $stdout.flush
    end
  end
end
