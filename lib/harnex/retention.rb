require "fileutils"
require "json"
require "set"
require "time"

module Harnex
  module Retention
    DIRS = {
      "events" => "events",
      "output" => "output",
      "receipts" => "receipts"
    }.freeze
    THROTTLE_SECONDS = 3600
    MAX_REPORTED_PATHS = 100
    METADATA_PATH = File.join(STATE_DIR, "retention.json").freeze
    LOCK_PATH = File.join(STATE_DIR, "retention.lock").freeze

    module_function

    def status(repo_root:, env: ENV, now: Time.now)
      limits = Config.retention_limits(repo_root, env: env)
      {
        ok: true,
        checked_at: now.utc.iso8601,
        config: limits,
        directories: DIRS.to_h do |key, dirname|
          files = inventory(File.join(STATE_DIR, dirname))
          [key, {
            path: File.join(STATE_DIR, dirname),
            count: files.length,
            bytes: files.sum { |file| file.fetch(:bytes) },
            max_age_days: limits.fetch(key).fetch("max_age_days"),
            max_bytes: limits.fetch(key).fetch("max_bytes")
          }]
        end,
        last_prune: last_prune_metadata
      }
    end

    def auto_prune(repo_root:, current_paths: [], env: ENV, now: Time.now)
      prune(
        repo_root: repo_root,
        current_paths: current_paths,
        env: env,
        now: now,
        dry_run: false,
        force: false
      )
    rescue Config::ConfigError
      raise
    rescue StandardError => e
      warn("harnex: retention prune failed: #{e.message}; run `harnex doctor --prune --dry-run` to inspect candidates")
      { ok: false, error: e.message }
    end

    def prune(repo_root:, current_paths: [], env: ENV, now: Time.now, dry_run: false, force: false)
      limits = Config.retention_limits(repo_root, env: env)
      with_lock do
        last = last_prune_metadata
        if !force && !dry_run && throttled?(last, now)
          return {
            ok: true,
            skipped: true,
            reason: "throttled",
            throttle_seconds: THROTTLE_SECONDS,
            last_prune: last
          }
        end

        protected = protected_paths(repo_root, current_paths)
        report = {
          ok: true,
          skipped: false,
          dry_run: dry_run,
          timestamp: now.utc.iso8601,
          directories: DIRS.to_h do |key, dirname|
            [key.to_sym, prune_directory(
              File.join(STATE_DIR, dirname),
              limits.fetch(key),
              protected,
              now,
              dry_run: dry_run
            )]
          end
        }
        persist_last_prune(report)
        report
      end
    end

    def inventory(dir)
      FileUtils.mkdir_p(dir)
      base = File.expand_path(dir)
      Dir.children(base).sort.filter_map do |name|
        path = File.expand_path(File.join(base, name))
        next unless path.start_with?("#{base}#{File::SEPARATOR}")

        stat = File.lstat(path)
        next unless stat.file?

        { path: path, bytes: stat.size, mtime: stat.mtime }
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
        nil
      end
    end

    def prune_directory(dir, limits, protected, now, dry_run:)
      files = inventory(dir)
      before_bytes = files.sum { |file| file.fetch(:bytes) }
      protected_files = files.select { |file| protected.include?(file.fetch(:path)) }
      deleted = []
      deleted_paths = Set.new
      projected_bytes = before_bytes

      cutoff = now - limits.fetch("max_age_days") * 86_400
      age_candidates = files.reject { |file| protected.include?(file.fetch(:path)) }
        .select { |file| file.fetch(:mtime) < cutoff }
        .sort_by { |file| [file.fetch(:mtime), file.fetch(:path)] }
      age_candidates.each do |file|
        next if deleted_paths.include?(file.fetch(:path))

        if delete_candidate(file, dry_run: dry_run)
          deleted << file
          deleted_paths.add(file.fetch(:path))
          projected_bytes -= file.fetch(:bytes)
        end
      end

      size_candidates = files.reject { |file| protected.include?(file.fetch(:path)) || deleted_paths.include?(file.fetch(:path)) }
        .sort_by { |file| [file.fetch(:mtime), file.fetch(:path)] }
      size_candidates.each do |file|
        break if projected_bytes <= limits.fetch("max_bytes")

        if delete_candidate(file, dry_run: dry_run)
          deleted << file
          deleted_paths.add(file.fetch(:path))
          projected_bytes -= file.fetch(:bytes)
        end
      end

      after_bytes = dry_run ? projected_bytes : inventory(dir).sum { |file| file.fetch(:bytes) }
      {
        path: dir,
        before_count: files.length,
        before_bytes: before_bytes,
        after_count: dry_run ? files.length - deleted.length : inventory(dir).length,
        after_bytes: after_bytes,
        deleted_count: deleted.length,
        deleted_bytes: deleted.sum { |file| file.fetch(:bytes) },
        deleted_paths: deleted.first(MAX_REPORTED_PATHS).map { |file| file.fetch(:path) },
        deleted_paths_truncated: deleted.length > MAX_REPORTED_PATHS,
        protected_count: protected_files.length,
        protected_bytes: protected_files.sum { |file| file.fetch(:bytes) },
        max_age_days: limits.fetch("max_age_days"),
        max_bytes: limits.fetch("max_bytes"),
        over_cap: after_bytes > limits.fetch("max_bytes")
      }
    end

    def delete_candidate(file, dry_run:)
      return true if dry_run

      File.delete(file.fetch(:path))
      true
    rescue Errno::ENOENT
      true
    rescue Errno::EACCES, Errno::EPERM, Errno::ENOTDIR
      false
    end

    def protected_paths(repo_root, current_paths)
      paths = Set.new
      current_paths.each { |path| protect(paths, path) }
      protect_live_registry_paths(paths)
      protect_live_start_row_paths(paths, repo_root)
      paths
    end

    def protect_live_registry_paths(paths)
      return unless Dir.exist?(SESSIONS_DIR)

      Dir.glob(File.join(SESSIONS_DIR, "*.json")).sort.each do |path|
        data = JSON.parse(File.read(path))
        next unless data["pid"] && Harnex.alive_pid?(data["pid"])

        protect(paths, data["events_log_path"])
        protect(paths, data["output_log_path"])
        protect(paths, data["artifact_report_path"])
        protect(paths, data["artifact_claims_path"])
        protect_derived_session_paths(paths, data)
      rescue JSON::ParserError, ArgumentError, TypeError, Errno::ENOENT, Errno::EACCES
        next
      end
    end

    def protect_live_start_row_paths(paths, repo_root)
      history_paths = [
        DispatchHistory.path_for(repo_root),
        DispatchHistory.global_path
      ].uniq

      history_paths.each do |path|
        live_start_records(path).each do |record|
          protect(paths, record["events_log_path"])
          protect(paths, record["output_log_path"])
          protect(paths, record["artifact_report_path"])
          protect(paths, record["artifact_claims_path"])
          protect_derived_session_paths(paths, record)
        end
      end
    end

    def live_start_records(path)
      return [] unless File.file?(path)

      open = {}
      File.foreach(path) do |line|
        record = JSON.parse(line)
        next unless record.is_a?(Hash)

        if DispatchHistory.start_record?(record)
          next unless DispatchHistory.same_host?(record)
          next unless record["pid"] && Harnex.alive_pid?(record["pid"])

          open[start_key(record)] = record
        elsif DispatchHistory.end_record?(record)
          open.delete_if { |_key, start| DispatchHistory.end_matches_start?(record, start) }
        end
      rescue JSON::ParserError, ArgumentError, TypeError
        next
      end
      open.values
    rescue Errno::ENOENT, Errno::EACCES
      []
    end

    def start_key(record)
      session_id = record["session_id"].to_s
      return "session:#{session_id}" unless session_id.empty?

      "id:#{record['id']}\0#{record['started_at']}"
    end

    def protect_derived_session_paths(paths, data)
      repo = data["repo_root"].to_s
      id = data["id"].to_s
      return if repo.empty? || id.empty?

      protect(paths, Harnex.events_log_path(repo, id))
      protect(paths, Harnex.output_log_path(repo, id))
      session_id = data["session_id"].to_s
      unless session_id.empty?
        receipt = Harnex::ArtifactReport.default_path(repo_root: repo, id: id, session_id: session_id)
        protect(paths, receipt)
        protect(paths, Harnex::ArtifactReport.claims_path(receipt))
      end
    rescue StandardError
      nil
    end

    def protect(paths, path)
      text = path.to_s
      return if text.empty?

      paths.add(File.expand_path(text))
    end

    def with_lock
      FileUtils.mkdir_p(STATE_DIR)
      File.open(LOCK_PATH, File::RDWR | File::CREAT, 0o644) do |file|
        file.flock(File::LOCK_EX)
        yield
      ensure
        file.flock(File::LOCK_UN) unless file.closed?
      end
    end

    def throttled?(last, now)
      timestamp = last.is_a?(Hash) ? last["timestamp"].to_s : ""
      return false if timestamp.empty?

      now - Time.parse(timestamp) < THROTTLE_SECONDS
    rescue ArgumentError
      false
    end

    def last_prune_metadata
      data = JSON.parse(File.read(METADATA_PATH))
      data["last_prune"]
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    def persist_last_prune(report)
      payload = {
        "last_prune" => {
          "timestamp" => report.fetch(:timestamp),
          "dry_run" => report.fetch(:dry_run),
          "applied" => !report.fetch(:dry_run),
          "directories" => report.fetch(:directories).transform_keys(&:to_s).transform_values do |stats|
            {
              "before_count" => stats.fetch(:before_count),
              "before_bytes" => stats.fetch(:before_bytes),
              "after_count" => stats.fetch(:after_count),
              "after_bytes" => stats.fetch(:after_bytes),
              "deleted_count" => stats.fetch(:deleted_count),
              "deleted_bytes" => stats.fetch(:deleted_bytes),
              "protected_count" => stats.fetch(:protected_count),
              "protected_bytes" => stats.fetch(:protected_bytes),
              "over_cap" => stats.fetch(:over_cap)
            }
          end
        }
      }
      Harnex.atomic_write_json(METADATA_PATH, payload)
    rescue StandardError => e
      warn("harnex: failed to persist retention metadata: #{e.message}")
    end
  end
end
