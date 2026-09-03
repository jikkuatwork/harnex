require "json"
require "net/http"
require "optparse"
require "time"
require "uri"

module Harnex
  class Status
    DESCRIPTION_WIDTH = 30
    REPO_WIDTH = 20
    REJECTED_OUTCOME_CLASSES = Session::PROOF_REJECTION_CLASSES

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
          With --id, terminal summaries can report completed/failed/unknown
          even after the live session registry is gone.
          Settled work outranks prompt state in the table: done, rejected, or failed.
          JSON `done`/`work_state` retains the structured work-level fields.
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
      active_repo_root = @options[:all] ? nil : Harnex.resolve_repo_root(@options[:repo_path])
      fallback_repo_root = Harnex.resolve_repo_root(@options[:repo_path])
      sessions = Harnex.active_sessions(active_repo_root, id: @options[:id])

      live = sessions.map { |session| normalize_live_status(load_live_status(session)) }
                     .sort_by { |session| [session["repo_root"].to_s, session["started_at"].to_s, session["id"].to_s] }
                     .reverse
      return live unless @options[:id]
      return [live.first] unless live.empty?

      running = running_from_start_record(fallback_repo_root)
      return [running] if running

      terminal = Harnex::TerminalStatus.resolve(id: @options[:id], repo_root: fallback_repo_root)
      [terminal || Harnex::TerminalStatus.unknown(id: @options[:id], repo_root: fallback_repo_root)]
    end

    # Registry row missing but the dispatch stream has an uncompleted start
    # row whose pid is alive: the worker is running, just not registry-visible
    # from this context. Report running (labelled degraded), never dead.
    def running_from_start_record(repo_root)
      start = Harnex::DispatchHistory.live_start_record(repo_root: repo_root, id: @options[:id])
      return nil unless start

      {
        "id" => start["id"].to_s,
        "cli" => start["cli"],
        "pid" => start["pid"],
        "description" => start["description"],
        "repo_root" => start["repo_root"] || repo_root,
        "started_at" => start["started_at"],
        "state" => "running",
        "process_state" => "running",
        "terminal" => false,
        "task_complete" => false,
        "task_failed" => false,
        "done" => false,
        "work_state" => "running",
        "exit" => nil,
        "exit_code" => nil,
        "ended_at" => nil,
        "source" => "dispatch_start",
        "degraded" => true,
        "live_status" => "unreachable"
      }
    end

    def normalize_live_status(session)
      task_failed = task_failed?(session)
      task_complete = task_complete?(session) && !task_failed
      work_state = task_failed ? "failed" : Harnex.work_state_for("running", task_complete: task_complete)
      degraded = session["live_status"] == "unreachable"
      session.merge(
        "state" => "running",
        "process_state" => "running",
        "terminal" => false,
        "task_complete" => task_complete,
        "task_failed" => task_failed,
        "done" => Harnex.work_done_for("running", task_complete: task_complete),
        "work_state" => work_state,
        "exit" => nil,
        "exit_code" => nil,
        "ended_at" => nil,
        "source" => degraded ? "registry" : "live",
        "degraded" => degraded
      )
    end

    def task_complete?(session)
      session["task_complete"] == true || session["task_complete"].to_s == "true" ||
        !session["last_completed_at"].to_s.empty?
    end

    def task_failed?(session)
      session["task_failed"] == true || session["task_failed"].to_s == "true" ||
        !session["last_failed_at"].to_s.empty?
    end

    # On HTTP failure the row is still backed by a verified-alive pid, but the
    # data is the registry snapshot, not the live API — label it as degraded
    # instead of silently passing it off as live.
    def load_live_status(session)
      uri = URI("http://#{session.fetch('host')}:#{session.fetch('port')}/status")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{session['token']}" if session["token"]

      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 0.25, read_timeout: 0.25) do |http|
        http.request(request)
      end

      return session.merge("live_status" => "unreachable") unless response.is_a?(Net::HTTPSuccess)

      session.merge(JSON.parse(response.body)).merge("live_status" => "ok")
    rescue StandardError
      session.merge("live_status" => "unreachable")
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
        "STATE" => table_state(session),
        "DESC" => truncate(session["description"])
      }
      row["REPO"] = truncate_repo(session["repo_root"])
      row
    end

    def format_row(row, columns, widths)
      columns.map { |column| row.fetch(column).ljust(widths.fetch(column)) }.join("  ")
    end

    def table_state(session)
      failed = task_failed?(session) || session["work_state"].to_s == "failed"
      completed = task_complete?(session) || session["work_state"].to_s == "completed"
      if failed || completed
        return "rejected" if rejected_work?(session)
        return failed ? "failed" : "done"
      end

      input_state = session.dig("input_state", "state").to_s
      return input_state unless input_state.empty?

      state = session["state"].to_s
      state.empty? ? "-" : state
    end

    def rejected_work?(session)
      return true if REJECTED_OUTCOME_CLASSES.include?(session["outcome_class"].to_s)

      !task_failed?(session) && session["artifact_report_status"].to_s == "rejected"
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
