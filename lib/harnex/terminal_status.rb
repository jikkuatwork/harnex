require "json"
require "time"

module Harnex
  module TerminalStatus
    module_function

    def resolve(id:, repo_root: Dir.pwd)
      normalized_id = Harnex.normalize_id(id)
      root = File.expand_path(repo_root.to_s.empty? ? Dir.pwd : repo_root)

      latest_summary = nil
      latest_summary_path = nil
      latest_history = nil

      history_paths(root).each do |path|
        summary, history = scan_dispatch_path(path, normalized_id)
        if newer_summary?(summary, latest_summary)
          latest_summary = summary
          latest_summary_path = path
        end
        latest_history = history if newer_history?(history, latest_history)
      end

      summary_path = latest_history && latest_history["summary_out_path"].to_s.strip
      if summary_path && !summary_path.empty? && File.file?(summary_path)
        summary, = scan_dispatch_path(summary_path, normalized_id)
        if newer_summary?(summary, latest_summary)
          latest_summary = summary
          latest_summary_path = summary_path
        end
      end

      return build_from_summary(latest_summary, latest_summary_path, root) if latest_summary
      return build_from_history(latest_history, root) if latest_history

      nil
    end

    def unknown(id:, repo_root: Dir.pwd)
      {
        "id" => Harnex.normalize_id(id),
        "repo_root" => File.expand_path(repo_root.to_s.empty? ? Dir.pwd : repo_root),
        "state" => "unknown",
        "process_state" => "unknown",
        "terminal" => false,
        "task_complete" => false,
        "task_failed" => false,
        "done" => false,
        "work_state" => "unknown",
        "outcome_class" => nil,
        "artifact_report_status" => nil,
        "exit" => nil,
        "exit_code" => nil,
        "summary_out" => nil,
        "started_at" => nil,
        "ended_at" => nil,
        "source" => "none"
      }
    end

    def history_paths(repo_root)
      local_path = DispatchHistory.path_for(repo_root)
      return [local_path] if File.file?(local_path)

      global_path = DispatchHistory.global_path
      return [global_path] if File.file?(global_path)

      []
    rescue StandardError
      []
    end

    def scan_dispatch_path(path, id)
      summary_record = nil
      history_record = nil

      File.foreach(path) do |line|
        record = JSON.parse(line)
        next unless record.is_a?(Hash)
        next if DispatchHistory.start_record?(record)

        # Branch on record_type first: a v2 end row carries both the thin
        # envelope and the rich sections, so it resolves as summary and
        # history in one shot — never double-counted via the legacy
        # duck-types below, which stay for pre-v2 files.
        if record["record_type"] == "dispatch_end"
          next unless record["id"].to_s == id

          history_record = record
          summary_record = record if summary_record?(record)
        elsif summary_record?(record) && record.dig("meta", "id").to_s == id
          summary_record = record
        elsif history_record?(record) && record["id"].to_s == id
          history_record = record
        end
      rescue JSON::ParserError
        next
      end

      [summary_record, history_record]
    rescue Errno::ENOENT
      [nil, nil]
    end

    def summary_record?(record)
      record["meta"].is_a?(Hash) && record["actual"].is_a?(Hash)
    end

    # Legacy thin end rows predate record_type.
    def history_record?(record)
      record["schema_version"] == 1 && record.key?("status")
    end

    def newer_summary?(candidate, current)
      return false unless candidate
      return true unless current

      summary_time(candidate) >= summary_time(current)
    end

    def newer_history?(candidate, current)
      return false unless candidate
      return true unless current

      history_time(candidate) >= history_time(current)
    end

    def summary_time(record)
      parse_time(record.dig("meta", "ended_at")) || parse_time(record.dig("meta", "started_at")) || Time.at(0)
    end

    def history_time(record)
      parse_time(record["ended_at"]) || parse_time(record["started_at"]) || Time.at(0)
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def build_from_summary(record, summary_path, fallback_repo_root)
      meta = record["meta"] || {}
      actual = record["actual"] || {}
      outcome = record["outcome"] || {}
      state = classify_summary_state(actual)
      task_complete = !!actual["task_complete"]
      task_failed = state == "failed" && !task_complete
      terminal = state != "unknown"
      {
        "id" => meta["id"].to_s,
        "repo_root" => meta["repo"] || fallback_repo_root,
        "state" => state,
        "process_state" => Harnex.process_state_for(state, terminal: terminal),
        "terminal" => terminal,
        "task_complete" => task_complete,
        "task_failed" => task_failed,
        "done" => Harnex.work_done_for(state, task_complete: task_complete),
        "work_state" => Harnex.work_state_for(state, task_complete: task_complete),
        "outcome_class" => blank_to_nil(outcome["class"]),
        "artifact_report_status" => blank_to_nil(outcome["report_status"]),
        "exit" => blank_to_nil(actual["exit"]),
        "exit_code" => actual["exit_code"],
        "summary_out" => summary_path,
        "started_at" => meta["started_at"],
        "ended_at" => meta["ended_at"],
        "source" => "summary_out"
      }
    end

    def classify_summary_state(actual)
      exit = actual["exit"].to_s
      exit_code = actual["exit_code"]

      return "completed" if exit == "success"
      return "completed" if exit.empty? && exit_code == 0
      return "failed" unless exit.empty? && exit_code.nil?

      "unknown"
    end

    def build_from_history(record, fallback_repo_root)
      status = record["status"].to_s
      state =
        case status
        when "completed"
          "completed"
        when "failed", "timeout", "killed"
          "failed"
        else
          "unknown"
        end
      task_complete = record["terminal_event"].to_s == "task_complete"
      task_failed = record["terminal_event"].to_s == "task_failed" || (state == "failed" && !task_complete)
      terminal = state != "unknown"
      {
        "id" => record["id"].to_s,
        "repo_root" => fallback_repo_root,
        "state" => state,
        "process_state" => Harnex.process_state_for(state, terminal: terminal),
        "terminal" => terminal,
        "task_complete" => task_complete,
        "task_failed" => task_failed,
        "done" => Harnex.work_done_for(state, task_complete: task_complete),
        "work_state" => Harnex.work_state_for(state, task_complete: task_complete),
        "outcome_class" => nil,
        "artifact_report_status" => nil,
        "exit" => history_exit(status),
        "exit_code" => nil,
        "summary_out" => blank_to_nil(record["summary_out_path"]),
        "started_at" => record["started_at"],
        "ended_at" => record["ended_at"],
        "source" => "dispatch_history"
      }
    end

    def history_exit(status)
      case status
      when "completed"
        "success"
      when "timeout"
        "timeout"
      when "killed"
        "killed"
      when "failed"
        "failure"
      else
        nil
      end
    end

    def blank_to_nil(value)
      text = value.to_s
      text.empty? ? nil : text
    end
  end
end
