require "json"
require "optparse"
require "set"
require "time"

module Harnex
  class History
    DEFAULT_LIMIT = 5

    def self.usage(program_name = "harnex history")
      <<~TEXT
        Usage: #{program_name} [options]

        Options:
          --limit N   Number of records to show (default: #{DEFAULT_LIMIT})
          --since DUR Only show records started within DUR (examples: 1h, 1d)
          --id TEXT   Filter records whose id contains TEXT
          --global    Read the global no-repo history file
          --json      Output JSONL instead of a table
          --all       Show all matching records
          -h, --help  Show this help
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {
        limit: DEFAULT_LIMIT,
        since: nil,
        id: nil,
        global: false,
        json: false,
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

      records = filtered_records
      if @options[:json]
        records.each { |record| puts JSON.generate(record) }
      elsif !records.empty?
        puts render_table(records)
      end
      0
    end

    private

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: harnex history [options]"
        opts.on("--limit N", Integer, "Number of records to show") do |value|
          raise OptionParser::InvalidArgument, "--limit must be greater than 0" if value <= 0

          @options[:limit] = value
        end
        opts.on("--since DUR", "Only show records started within DUR") { |value| @options[:since] = parse_since(value) }
        opts.on("--id TEXT", "Filter records by id substring") { |value| @options[:id] = value.to_s }
        opts.on("--global", "Read the global no-repo history file") { @options[:global] = true }
        opts.on("--json", "Output JSONL") { @options[:json] = true }
        opts.on("--all", "Show all matching records") { @options[:all] = true }
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end

    def parse_since(value)
      Time.now - Harnex.parse_duration_seconds(value, option_name: "--since")
    end

    def filtered_records
      records = derived_records
      records = records.select { |record| record["id"].to_s.include?(@options[:id]) } if @options[:id]
      records = records.select { |record| started_after?(record, @options[:since]) } if @options[:since]
      records = records.last(@options[:limit]) unless @options[:all]
      records
    end

    # One row per dispatch: start rows completed by an end row are dropped
    # (the end row carries the outcome); uncompleted start rows surface as
    # running (pid alive on this host) or interrupted (no end row, pid gone).
    def derived_records
      raw = load_records
      ended = Set.new
      raw.each do |record|
        next unless DispatchHistory.end_record?(record)

        session_id = record["session_id"].to_s
        ended << "sid:#{session_id}" unless session_id.empty?
        ended << "leg:#{record['id']}|#{record['started_at']}"
      end

      raw.filter_map do |record|
        next record unless DispatchHistory.start_record?(record)
        next nil if start_completed?(record, ended)

        derive_live_record(record)
      end
    end

    def start_completed?(record, ended)
      session_id = record["session_id"].to_s
      return true if !session_id.empty? && ended.include?("sid:#{session_id}")

      ended.include?("leg:#{record['id']}|#{record['started_at']}")
    end

    def derive_live_record(record)
      alive = DispatchHistory.same_host?(record) &&
              record["pid"] && Harnex.alive_pid?(record["pid"])
      record.merge(
        "status" => alive ? "running" : "interrupted",
        "terminal_event" => nil,
        "duration_s" => alive ? seconds_since(record["started_at"]) : nil,
        "ended_at" => nil
      )
    end

    def seconds_since(timestamp)
      seconds = (Time.now - Time.iso8601(timestamp.to_s)).to_i
      seconds.negative? ? 0 : seconds
    rescue ArgumentError
      nil
    end

    def load_records
      path = DispatchHistory.path_for(Dir.pwd, global: @options[:global])
      return [] unless File.file?(path)

      File.readlines(path, chomp: true).filter_map do |line|
        next if line.strip.empty?

        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end

    def started_after?(record, floor)
      Time.iso8601(record.fetch("started_at")) >= floor
    rescue KeyError, ArgumentError
      false
    end

    def render_table(records)
      columns = ["ID", "STARTED", "DURATION", "STATUS", "COMMIT", "TERMINAL", "TMUX"]
      rows = records.map { |record| table_row(record) }
      widths = columns.to_h { |column| [column, ([column.length] + rows.map { |row| row.fetch(column).length }).max] }

      ([columns.to_h { |column| [column, column] }] + rows)
        .map { |row| columns.map { |column| row.fetch(column).ljust(widths.fetch(column)) }.join("  ") }
        .join("\n")
    end

    def table_row(record)
      {
        "ID" => record["id"].to_s,
        "STARTED" => format_started(record["started_at"]),
        "DURATION" => format_duration(record["duration_s"]),
        "STATUS" => record["status"].to_s,
        "COMMIT" => short_commit(record["commit_sha"]),
        "TERMINAL" => record["terminal_event"].to_s,
        "TMUX" => record["tmux_state"].to_s
      }
    end

    def format_started(value)
      Time.iso8601(value.to_s).getlocal.strftime("%Y-%m-%d %H:%M")
    rescue ArgumentError
      "-"
    end

    def format_duration(value)
      return "-" if value.nil?

      seconds = Integer(value)
      hours = seconds / 3600
      minutes = (seconds % 3600) / 60
      rest = seconds % 60
      return "#{hours}h#{minutes.to_s.rjust(2, '0')}m" if hours.positive?
      return "#{minutes}m#{rest.to_s.rjust(2, '0')}s" if minutes.positive?

      "#{rest}s"
    rescue ArgumentError
      "-"
    end

    def short_commit(value)
      text = value.to_s
      text.empty? ? "-" : text[0, 8]
    end
  end
end
