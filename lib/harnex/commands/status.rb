require "json"
require "net/http"
require "optparse"
require "time"
require "uri"

module Harnex
  class Status
    def self.usage(program_name = "harnex status")
      <<~TEXT
        Usage: #{program_name} [options]

        Options:
          --repo PATH   List sessions for PATH's repo root (default: current repo)
          --all         List sessions across all repos
          -h, --help    Show this help
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {
        repo_path: Dir.pwd,
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

      sessions = load_sessions
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
        opts.on("--repo PATH", "List sessions for PATH's repo root") { |value| @options[:repo_path] = Harnex.ensure_option_value!("--repo", value) }
        opts.on("--all", "List sessions across all repos") { @options[:all] = true }
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end

    def load_sessions
      sessions =
        if @options[:all]
          Harnex.active_sessions
        else
          Harnex.active_sessions(Harnex.resolve_repo_root(@options[:repo_path]))
        end

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
      columns = ["ID", "CLI", "PID", "PORT", "AGE", "LAST", "STATE"]
      columns << "REPO" if @options[:all]

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
        "LAST" => timeago(session["last_injected_at"], none: "never"),
        "STATE" => session.dig("input_state", "state").to_s.empty? ? "-" : session.dig("input_state", "state").to_s
      }
      row["REPO"] = display_path(session["repo_root"]) if columns.include?("REPO")
      row
    end

    def format_row(row, columns, widths)
      columns.map { |column| row.fetch(column).ljust(widths.fetch(column)) }.join("  ")
    end

    def timeago(timestamp, none: "-")
      return none if timestamp.to_s.empty?

      seconds = (Time.now - Time.parse(timestamp.to_s)).to_i
      seconds = 0 if seconds.negative?

      case seconds
      when 0...60
        "#{seconds}s ago"
      when 60...3600
        "#{seconds / 60}m ago"
      when 3600...86_400
        "#{seconds / 3600}h ago"
      else
        "#{seconds / 86_400}d ago"
      end
    rescue StandardError
      timestamp.to_s
    end

    def display_path(path)
      path.to_s.sub(/\A#{Regexp.escape(Dir.home)}/, "~")
    end
  end
end
