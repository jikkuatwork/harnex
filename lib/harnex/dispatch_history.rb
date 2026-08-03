require "fileutils"
require "json"
require "open3"
require "time"

module Harnex
  module DispatchHistory
    module_function

    MAX_REPO_WALK_LEVELS = 10

    # v2 marks the unified era: one rich dispatch_end row per dispatch
    # carrying both the thin envelope and the summary sections. Readers
    # key on record_type, not this stamp; legacy clauses keep accepting
    # v1 and envelope-less rows mixed in the same file.
    SCHEMA_VERSION = 2

    def global_path
      File.join(STATE_DIR, "dispatch.jsonl")
    end

    def path_for(start_path = Dir.pwd, global: false)
      return global_path if global

      repo_root = find_git_root(start_path)
      return global_path unless repo_root

      File.join(repo_root, ".harnex", "dispatch.jsonl")
    end

    def find_git_root(start_path)
      path = File.expand_path(start_path.to_s.empty? ? Dir.pwd : start_path)
      path = File.dirname(path) unless File.directory?(path)

      git_root = git_toplevel(path)
      return git_root if git_root

      (MAX_REPO_WALK_LEVELS + 1).times do
        return path if File.directory?(File.join(path, ".git"))

        parent = File.dirname(path)
        break if parent == path

        path = parent
      end

      nil
    end

    def git_toplevel(path)
      output, status = Open3.capture2("git", "-C", path, "rev-parse", "--show-toplevel", err: File::NULL)
      root = output.to_s.strip
      return root if status.success? && !root.empty?

      nil
    rescue StandardError
      nil
    end

    def append(path, record)
      FileUtils.mkdir_p(File.dirname(path))
      line = JSON.generate(record) + "\n"
      File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o644) do |file|
        file.flock(File::LOCK_EX)
        file.write(line)
      ensure
        file.flock(File::LOCK_UN) unless file.closed?
      end
    end

    def start_record?(record)
      record.is_a?(Hash) && record["record_type"] == "dispatch_start"
    end

    def end_record?(record)
      return false unless record.is_a?(Hash)
      return true if record["record_type"] == "dispatch_end"

      # Legacy end rows predate record_type.
      record["schema_version"] == 1 && record.key?("status") && !record.key?("record_type")
    end

    def end_matches_start?(end_record, start_record)
      end_session = end_record["session_id"].to_s
      start_session = start_record["session_id"].to_s
      return end_session == start_session unless end_session.empty? || start_session.empty?

      end_record["id"].to_s == start_record["id"].to_s &&
        end_record["started_at"].to_s == start_record["started_at"].to_s
    end

    # Latest start row for `id` and any end row that completes it.
    def latest_rows(path, id)
      latest_start = nil
      matching_end = nil

      return { start: nil, end: nil } unless File.file?(path)

      File.foreach(path) do |line|
        record = JSON.parse(line)
        next unless record.is_a?(Hash)
        next unless record["id"].to_s == id

        if start_record?(record)
          latest_start = record
          matching_end = nil
        elsif end_record?(record)
          matching_end = record if latest_start && end_matches_start?(record, latest_start)
        end
      rescue JSON::ParserError
        next
      end

      { start: latest_start, end: matching_end }
    end

    # A dispatch_start row with no completing end row whose pid is alive on
    # this host — evidence of a running session even when the live registry
    # is not visible from the caller's context.
    def live_start_record(repo_root:, id:)
      normalized_id = Harnex.normalize_id(id)
      rows = latest_rows(path_for(repo_root), normalized_id)
      start = rows[:start]
      return nil unless start
      return nil if rows[:end]
      return nil unless same_host?(start)

      pid = start["pid"]
      return nil unless pid && Harnex.alive_pid?(pid)

      start
    rescue StandardError
      nil
    end

    def same_host?(record)
      host = record["host"].to_s
      return true if host.empty?

      host == Harnex.host_info[:host].to_s
    end

    # Appended at registration so a running dispatch always has a durable
    # trace; the dispatch_end row written in finalize_session! completes it.
    def build_start_record(session)
      {
        schema_version: SCHEMA_VERSION,
        record_type: "dispatch_start",
        id: session.id,
        session_id: session.session_id,
        pid: session.pid,
        host: Harnex.host_info[:host],
        cli: session.adapter.key,
        description: session.description,
        started_at: session.started_at.utc.iso8601,
        repo_root: session.repo_root,
        tier: session.__send__(:meta_hash)["tier"],
        meta: session.__send__(:meta_hash),
        summary_out_path: session.summary_out,
        events_log_path: session.events_log_path,
        artifact_report_path: session.artifact_report_path,
        artifact_claims_path: session.artifact_claims_path
      }
    end

    # The v2 end row: the thin envelope merged with the rich summary
    # sections. The envelope carries no raw meta passthrough — the summary's
    # meta section (a superset with provenance) rides in its place; top-level
    # tier stays for the history renderer.
    def build_record(session)
      ended_at = session.ended_at || Time.now
      status, terminal_event = classify(session)
      {
        schema_version: SCHEMA_VERSION,
        record_type: "dispatch_end",
        id: session.id,
        session_id: session.session_id,
        description: session.description,
        cli: session.adapter.key,
        started_at: session.started_at.utc.iso8601,
        ended_at: ended_at.utc.iso8601,
        duration_s: (ended_at - session.started_at).to_i,
        status: status,
        terminal_event: terminal_event,
        commit_sha: commit_sha(session.git_start, session.git_end),
        tier: session.__send__(:meta_hash)["tier"],
        summary_out_path: session.summary_out,
        events_log_path: session.events_log_path,
        tmux_state: tmux_state(session.__send__(:summary_tmux_session))
      }.merge(session.__send__(:build_summary_record))
    end

    def classify(session)
      return ["failed", "task_failed"] if session.respond_to?(:task_failed?) && session.task_failed?
      return ["completed", "task_complete"] if session.task_complete?
      return ["timeout", "timeout"] if session.exit_code == 124
      return ["killed", "process_kill"] if session.term_signal
      return ["completed", "process_exit"] if session.exit_code == 0

      ["failed", "dispatch_failed"]
    end

    def commit_sha(git_start, git_end)
      start_sha = git_start[:sha].to_s
      end_sha = git_end[:sha].to_s
      return nil if start_sha.empty? || end_sha.empty? || start_sha == end_sha

      end_sha
    end

    def tmux_state(tmux_session)
      return "torn-down" if tmux_session.to_s.empty?

      system("tmux", "has-session", "-t", tmux_session.to_s, out: File::NULL, err: File::NULL) ? "live" : "torn-down"
    rescue StandardError
      "torn-down"
    end
  end
end
