require "json"
require "optparse"
require "open3"
require "time"

module Harnex
  class Pane
    def self.usage(program_name = "harnex pane")
      <<~TEXT
        Usage: #{program_name} [options]

        Options:
          --id ID       Session ID to inspect (required)
          --repo PATH   Resolve using PATH's repo root (default: current repo)
          --cli CLI     Filter the active session by CLI
          --lines N     Capture the last N lines instead of the full pane
          --json        Output JSON with capture metadata
          -h, --help    Show this help
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {
        id: nil,
        repo_path: Dir.pwd,
        cli: nil,
        lines: nil,
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

      window = session.fetch("id")
      return 1 unless tmux_window_exists?(window)

      text = capture(window)
      return 1 unless text

      emit_output(session.fetch("id"), text)
      0
    end

    private

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: harnex pane [options]"
        opts.on("--id ID", "Session ID to inspect") { |value| @options[:id] = Harnex.normalize_id(value) }
        opts.on("--repo PATH", "Resolve using PATH's repo root") { |value| @options[:repo_path] = value }
        opts.on("--cli CLI", "Filter the active session by CLI") { |value| @options[:cli] = value }
        opts.on("--lines N", Integer, "Capture the last N lines instead of the full pane") { |value| @options[:lines] = value }
        opts.on("--json", "Output JSON with capture metadata") { @options[:json] = true }
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end

    def resolve_session
      repo_root = Harnex.resolve_repo_root(@options[:repo_path])
      session = Harnex.read_registry(repo_root, @options[:id], cli: @options[:cli])
      return session if session

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

    def tmux_available?
      return true if system("tmux", "-V", out: File::NULL, err: File::NULL)

      warn("harnex pane: tmux is not installed or not available in PATH")
      false
    rescue Errno::ENOENT
      warn("harnex pane: tmux is not installed or not available in PATH")
      false
    end

    def tmux_window_exists?(window)
      return true if system("tmux", "has-session", "-t", window, out: File::NULL, err: File::NULL)

      warn("harnex pane: session #{window.inspect} is not tmux-backed or the tmux window no longer exists")
      false
    rescue Errno::ENOENT
      warn("harnex pane: tmux is not installed or not available in PATH")
      false
    end

    def capture(window)
      stdout, stderr, status = capture_command(capture_command_args(window))
      return stdout if status.success?

      message = stderr.to_s.strip
      message = "tmux capture-pane failed" if message.empty?
      warn("harnex pane: #{message}")
      nil
    rescue Errno::ENOENT
      warn("harnex pane: tmux is not installed or not available in PATH")
      nil
    end

    def capture_command_args(window)
      command = ["tmux", "capture-pane", "-t", window, "-p"]
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
