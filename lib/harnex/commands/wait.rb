require "json"
require "optparse"

module Harnex
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
      exit_path = Harnex.exit_status_path(repo_root, @options[:id])

      # First, try to find the live session
      registry = Harnex.read_registry(repo_root, @options[:id])
      unless registry
        # Fallback: session may have already exited — check exit status file
        return read_exit_status(exit_path, @options[:id]) if File.exist?(exit_path)

        warn("harnex wait: no session found with id #{@options[:id].inspect}")
        return 1
      end

      target_pid = registry["pid"]
      warn("harnex wait: watching session #{@options[:id]} (pid #{target_pid})")

      # Poll until the process exits
      loop do
        unless Harnex.alive_pid?(target_pid)
          return read_exit_status(exit_path, @options[:id])
        end

        if deadline && Time.now >= deadline
          puts JSON.generate(ok: false, id: @options[:id], status: "timeout", pid: target_pid)
          return 124
        end

        sleep POLL_INTERVAL
      end
    end

    private

    def read_exit_status(exit_path, id)
      if File.exist?(exit_path)
        data = JSON.parse(File.read(exit_path))
        puts JSON.generate(data)
        data["exit_code"] || 0
      else
        puts JSON.generate(ok: true, id: id, status: "exited")
        0
      end
    end

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
end
