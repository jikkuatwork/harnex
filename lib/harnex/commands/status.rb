require "json"
require "net/http"
require "optparse"
require "time"
require "uri"

module Harnex
  class Status
    DESCRIPTION_WIDTH = 30
    REPO_WIDTH = 20

    def self.usage(program_name = "harnex status")
      <<~TEXT
        Usage: #{program_name} [options]

        Options:
          --id ID      Show a specific session
          --repo PATH  Filter to PATH's repo root (default: current repo)
          --all        List sessions across all repos
          --json       Output JSON instead of a table
          -h, --help   Show this help

        Common patterns:
          #{program_name}
          #{program_name} --all
          #{program_name} --id cx-i-42 --json

        Gotchas:
          By default, status filters to the current repo root.
          Use --all when supervising workers launched from sibling worktrees.
          A prompt-like state is not a completion signal by itself.
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {
        id: nil,
        repo_path: Dir.pwd,
        all: false,
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

      sessions = load_sessions
      if @options[:json]
        puts JSON.generate(sessions)
        return 0
      end

      if sessions.empty?
        if @options[:all]
          puts "No active harnex sessions."
        else
          puts "No active harnex sessions for #{Harnex.resolve_repo_root(@options[:repo_path])}."
        end
        return 0
      end

      puts render_table(sessions)
      0
    end

    private

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: harnex status [options]"
        opts.on("--id ID", "Show a specific session") { |value| @options[:id] = Harnex.normalize_id(value) }
        opts.on("--repo PATH", "Filter to PATH's repo root") { |value| @options[:repo_path] = value }
        opts.on("--all", "List sessions across all repos") { @options[:all] = true }
        opts.on("--json", "Output JSON instead of a table") { @options[:json] = true }
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end

    def load_sessions
      repo_root = @options[:all] ? nil : Harnex.resolve_repo_root(@options[:repo_path])
      sessions = Harnex.active_sessions(repo_root, id: @options[:id])

      sessions.map { |session| load_live_status(session) }
        .sort_by { |session| [session["repo_root"].to_s, session["started_at"].to_s, session["id"].to_s] }
        .reverse
    end

    def load_live_status(session)
      uri = URI("http://#{session.fetch('host')}:#{session.fetch('port')}/status")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{session['token']}" if session["token"]

      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 0.25, read_timeout: 0.25) do |http|
        http.request(request)
      end

      return session unless response.is_a?(Net::HTTPSuccess)

      session.merge(JSON.parse(response.body))
    rescue StandardError
      session
    end

    def render_table(sessions)
      columns = ["ID", "CLI", "PID", "PORT", "AGE", "IDLE", "STATE", "REPO", "DESC"]

      rows = sessions.map { |session| table_row(session, columns) }
      widths = columns.to_h { |column| [column, ([column.length] + rows.map { |row| row.fetch(column).length }).max] }

      lines = []
      lines << format_row(columns.to_h { |column| [column, column] }, columns, widths)
      lines << format_row(columns.to_h { |column| [column, "-" * widths.fetch(column)] }, columns, widths)
      lines.concat(rows.map { |row| format_row(row, columns, widths) })
      lines.join("\n")
    end

    def table_row(session, columns)
      row = {
        "ID" => session["id"].to_s,
        "CLI" => Harnex.session_cli(session).empty? ? "-" : Harnex.session_cli(session),
        "PID" => session["pid"].to_s,
        "PORT" => session["port"].to_s,
        "AGE" => timeago(session["started_at"]),
        "IDLE" => format_idle(session["log_idle_s"]),
        "STATE" => session.dig("input_state", "state").to_s.empty? ? "-" : session.dig("input_state", "state").to_s,
        "DESC" => truncate(session["description"])
      }
      row["REPO"] = truncate_repo(session["repo_root"])
      row
    end

    def format_row(row, columns, widths)
      columns.map { |column| row.fetch(column).ljust(widths.fetch(column)) }.join("  ")
    end

    def timeago(timestamp)
      return "-" if timestamp.to_s.empty?

      seconds = (Time.now - Time.parse(timestamp.to_s)).to_i
      seconds = 0 if seconds.negative?
      compact_duration(seconds)
    rescue StandardError
      timestamp.to_s
    end

    def format_idle(idle_seconds)
      return "-" if idle_seconds.nil?

      seconds = Integer(idle_seconds)
      seconds = 0 if seconds.negative?
      compact_duration(seconds)
    rescue StandardError
      "-"
    end

    def compact_duration(seconds)
      case seconds
      when 0...60
        "#{seconds}s"
      when 60...3600
        "#{seconds / 60}m"
      when 3600...86_400
        "#{seconds / 3600}h"
      else
        "#{seconds / 86_400}d"
      end
    end

    def truncate(value)
      text = value.to_s
      return "-" if text.empty?
      return text if text.length <= DESCRIPTION_WIDTH

      "#{text[0, DESCRIPTION_WIDTH - 3]}..."
    end

    def truncate_repo(path)
      text = display_path(path)
      return "-" if text.empty?
      return text if text.length <= REPO_WIDTH

      "..#{text[-(REPO_WIDTH - 2)..]}"
    end

    def display_path(path)
      path.to_s.sub(/\A#{Regexp.escape(Dir.home)}/, "~")
    end
  end
end
