require "fileutils"
require "json"
require "time"

module Harnex
  module DispatchHistory
    module_function

    MAX_REPO_WALK_LEVELS = 10

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

      (MAX_REPO_WALK_LEVELS + 1).times do
        return path if File.directory?(File.join(path, ".git"))

        parent = File.dirname(path)
        break if parent == path

        path = parent
      end

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

    def build_record(session)
      ended_at = session.ended_at || Time.now
      status, terminal_event = classify(session)
      {
        schema_version: 1,
        id: session.id,
        description: session.description,
        cli: session.adapter.key,
        started_at: session.started_at.utc.iso8601,
        ended_at: ended_at.utc.iso8601,
        duration_s: (ended_at - session.started_at).to_i,
        status: status,
        terminal_event: terminal_event,
        commit_sha: commit_sha(session.git_start, session.git_end),
        tier: session.__send__(:meta_hash)["tier"],
        meta: session.__send__(:meta_hash),
        summary_out_path: session.summary_out,
        events_log_path: session.events_log_path,
        tmux_state: tmux_state(session.__send__(:summary_tmux_session))
      }
    end

    def classify(session)
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
