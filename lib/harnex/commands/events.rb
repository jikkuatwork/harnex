require "json"
require "optparse"
require "time"

module Harnex
  class Events
    POLL_INTERVAL = 0.1

    def self.usage(program_name = "harnex events")
      <<~TEXT
        Usage: #{program_name} [options]

        Options:
          --id ID         Session ID to inspect (required)
          --repo PATH     Resolve using PATH's repo root (default: current repo)
          --cli CLI       Filter the active session by CLI
          --[no-]follow   Keep streaming appended events (default: true)
          --snapshot      Print current events and exit (alias for --no-follow)
          --from TS       Replay floor (ISO-8601, inclusive)
          -h, --help      Show this help

        Common patterns:
          #{program_name} --id cx-i-42 --snapshot
          #{program_name} --id cx-i-42
          #{program_name} --id cx-i-42 --from 2026-05-06T10:00:00Z --snapshot

        Gotchas:
          events is structured JSONL; logs is human transcript text.
          Default mode follows live events. Use --snapshot to print and exit.
          Use wait --until task_complete when you only need a completion fence.
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {
        id: nil,
        repo_path: Dir.pwd,
        cli: nil,
        follow: true,
        from: nil,
        help: false
      }
      @tail_buffer = +""
    end

    def run
      parser.parse!(@argv)
      if @options[:help]
        puts self.class.usage
        return 0
      end

      raise "--id is required for harnex events" unless @options[:id]

      target = resolve_target
      return 1 unless target

      offset = print_snapshot(target.fetch(:path))
      return 0 unless @options[:follow] && target[:live]

      follow(target.fetch(:path), offset)
    end

    private

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: harnex events [options]"
        opts.on("--id ID", "Session ID to inspect") { |value| @options[:id] = Harnex.normalize_id(value) }
        opts.on("--repo PATH", "Resolve using PATH's repo root") { |value| @options[:repo_path] = value }
        opts.on("--cli CLI", "Filter the active session by CLI") { |value| @options[:cli] = value }
        opts.on("--[no-]follow", "Keep streaming appended events") { |value| @options[:follow] = value }
        opts.on("--snapshot", "Print current events and exit") { @options[:follow] = false }
        opts.on("--from TS", "Replay floor (ISO-8601, inclusive)") { |value| @options[:from] = parse_from(value) }
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end

    def parse_from(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      raise OptionParser::InvalidArgument, "--from must be an ISO-8601 timestamp"
    end

    def resolve_target
      repo_root = Harnex.resolve_repo_root(@options[:repo_path])
      session = Harnex.read_registry(repo_root, @options[:id], cli: @options[:cli])

      if session
        path = session["events_log_path"].to_s
        path = Harnex.events_log_path(repo_root, @options[:id]) if path.empty?
        return event_target(path, live: true, repo_root: repo_root)
      end

      if cli_filter_mismatch?(repo_root)
        warn("harnex events: no active session found with id #{@options[:id].inspect} and cli #{@options[:cli].inspect}")
        return nil
      end

      event_target(Harnex.events_log_path(repo_root, @options[:id]), live: false, repo_root: repo_root)
    end

    def cli_filter_mismatch?(repo_root)
      return false unless @options[:cli]

      session = Harnex.read_registry(repo_root, @options[:id])
      return false unless session

      Harnex.cli_key(Harnex.session_cli(session)) != Harnex.cli_key(@options[:cli])
    end

    def event_target(path, live:, repo_root:)
      return { path: path, live: live, repo_root: repo_root } if File.file?(path)

      if live
        warn("harnex events: stream not found at #{path}")
      else
        warn("harnex events: no session or event stream found with id #{@options[:id].inspect} for #{repo_root}")
      end
      nil
    end

    def print_snapshot(path)
      offset = 0
      File.open(path, "rb") do |file|
        file.each_line do |line|
          next unless emit_line?(line)

          $stdout.write(line)
        end
        offset = file.pos
      end
      $stdout.flush
      offset
    end

    def follow(path, offset)
      current_offset = offset

      loop do
        streamed = stream_growth(path, current_offset)
        return streamed.fetch(:code) if streamed[:code]

        current_offset = streamed.fetch(:offset)
        sleep POLL_INTERVAL
      end
    end

    def stream_growth(path, offset)
      unless File.file?(path)
        warn("harnex events: stream source disappeared at #{path}")
        return { code: 1, offset: offset }
      end

      size = File.size(path)
      if size < offset
        warn("harnex events: stream source was truncated at #{path}")
        return { code: 1, offset: size }
      end
      return { offset: offset } if size == offset

      chunk = +""
      File.open(path, "rb") do |file|
        file.seek(offset)
        chunk = file.read(size - offset).to_s
      end

      @tail_buffer << chunk
      lines = @tail_buffer.split("\n", -1)
      @tail_buffer = lines.pop || +""
      wrote = false

      lines.each do |line|
        json_line = "#{line}\n"
        event = parse_event(json_line)
        if emit_line?(json_line, parsed: event)
          $stdout.write(json_line)
          wrote = true
        end
        return { code: 0, offset: size } if target_exited?(event)
      end

      $stdout.flush if wrote
      { offset: size }
    end

    def emit_line?(line, parsed: nil)
      return true unless @options[:from]

      event = parsed || parse_event(line)
      return false unless event

      timestamp = event_timestamp(event)
      return false unless timestamp

      timestamp >= @options[:from]
    end

    def parse_event(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    def event_timestamp(event)
      value = event["ts"].to_s
      return nil if value.empty?

      Time.iso8601(value)
    rescue ArgumentError
      nil
    end

    def target_exited?(event)
      return false unless event
      return false unless event["type"] == "exited"

      Harnex.id_key(event["id"].to_s) == Harnex.id_key(@options[:id])
    end
  end
end
