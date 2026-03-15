require "optparse"

module Harnex
  class Logs
    DEFAULT_LINES = 200
    POLL_INTERVAL = 0.1
    READ_CHUNK_SIZE = 4096

    def self.usage(program_name = "harnex logs")
      <<~TEXT
        Usage: #{program_name} [options]

        Options:
          --id ID       Session ID to inspect (required)
          --repo PATH   Resolve using PATH's repo root (default: current repo)
          --cli CLI     Filter the active session by CLI
          --follow      Keep streaming appended output until session exit
          --lines N     Print the last N lines before following (default: #{DEFAULT_LINES})
          -h, --help    Show this help
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {
        id: nil,
        repo_path: Dir.pwd,
        cli: nil,
        follow: false,
        lines: DEFAULT_LINES,
        help: false
      }
    end

    def run
      parser.parse!(@argv)
      if @options[:help]
        puts self.class.usage
        return 0
      end

      raise "--id is required for harnex logs" unless @options[:id]
      raise OptionParser::InvalidArgument, "--lines must be >= 0" if @options[:lines].negative?

      target = resolve_target
      return 1 unless target

      offset = print_snapshot(target.fetch(:path))
      return 0 unless @options[:follow] && target[:live]

      follow(target.fetch(:path), offset, target.fetch(:pid))
      0
    end

    private

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: harnex logs [options]"
        opts.on("--id ID", "Session ID to inspect") { |value| @options[:id] = Harnex.normalize_id(value) }
        opts.on("--repo PATH", "Resolve using PATH's repo root") { |value| @options[:repo_path] = value }
        opts.on("--cli CLI", "Filter the active session by CLI") { |value| @options[:cli] = value }
        opts.on("--follow", "Keep streaming appended output until session exit") { @options[:follow] = true }
        opts.on("--lines N", Integer, "Print the last N lines before following") { |value| @options[:lines] = value }
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end

    def resolve_target
      repo_root = Harnex.resolve_repo_root(@options[:repo_path])
      session = Harnex.read_registry(repo_root, @options[:id], cli: @options[:cli])

      if session
        path = session["output_log_path"].to_s
        path = Harnex.output_log_path(repo_root, @options[:id]) if path.empty?
        return log_target(path, live: true, pid: session["pid"], repo_root: repo_root)
      end

      if cli_filter_mismatch?(repo_root)
        warn("harnex logs: no active session found with id #{@options[:id].inspect} and cli #{@options[:cli].inspect}")
        return nil
      end

      log_target(Harnex.output_log_path(repo_root, @options[:id]), live: false, pid: nil, repo_root: repo_root)
    end

    def cli_filter_mismatch?(repo_root)
      return false unless @options[:cli]

      session = Harnex.read_registry(repo_root, @options[:id])
      return false unless session

      Harnex.cli_key(Harnex.session_cli(session)) != Harnex.cli_key(@options[:cli])
    end

    def log_target(path, live:, pid:, repo_root:)
      return { path: path, live: live, pid: pid, repo_root: repo_root } if File.file?(path)

      if live
        warn("harnex logs: transcript not found at #{path}")
      else
        warn("harnex logs: no session or transcript found with id #{@options[:id].inspect} for #{repo_root}")
      end
      nil
    end

    def print_snapshot(path)
      data, offset = snapshot_data(path, @options[:lines])
      $stdout.write(data)
      $stdout.flush
      offset
    end

    def snapshot_data(path, line_limit)
      size = File.size?(path).to_i
      return ["".b, size] if size.zero? || line_limit.zero?

      offset = size
      buffer = +"".b

      File.open(path, "rb") do |file|
        while offset.positive?
          chunk_size = [READ_CHUNK_SIZE, offset].min
          offset -= chunk_size
          file.seek(offset)
          chunk = file.read(chunk_size)
          next if chunk.nil? || chunk.empty?

          buffer = chunk.b + buffer
          break if buffer.count("\n") >= line_limit
        end
      end

      lines = buffer.lines
      data =
        if lines.length > line_limit
          lines.last(line_limit).join
        else
          buffer
        end
      [data, size]
    end

    def follow(path, offset, pid)
      current_offset = offset

      loop do
        current_offset = stream_growth(path, current_offset)
        unless Harnex.alive_pid?(pid)
          drain_growth(path, current_offset)
          return
        end

        sleep POLL_INTERVAL
      end
    end

    def drain_growth(path, offset)
      current_offset = offset

      loop do
        next_offset = stream_growth(path, current_offset)
        return next_offset if next_offset == current_offset

        current_offset = next_offset
      end
    end

    def stream_growth(path, offset)
      size = File.size?(path).to_i
      offset = size if offset > size
      return offset if size == offset

      File.open(path, "rb") do |file|
        file.seek(offset)
        while (chunk = file.read(READ_CHUNK_SIZE))
          $stdout.write(chunk)
        end
      end
      $stdout.flush
      size
    end
  end
end
