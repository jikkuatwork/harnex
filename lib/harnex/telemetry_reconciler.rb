require "fileutils"
require "json"
require "set"
require "time"

module Harnex
  class TelemetryReconciler
    SCHEMA = "harnex.telemetry_reconcile.v1"
    FAMILY_KEYS = %w[v2_start v2_end v1_end legacy_rich legacy_unknown].freeze
    RICH_KEYS = %w[predicted agent usage context attribution outcome attempt reliability].freeze
    MAX_DIAGNOSTICS = 50

    Result = Struct.new(:report, :exitstatus, keyword_init: true)
    Row = Struct.new(:record, :path, :line, :family, :identity, :match_identity, :sort_key, keyword_init: true)

    def initialize(command:, canonical:, sources:, apply: false)
      @command = command
      @canonical = canonical
      @sources = sources
      @apply = apply
      @diagnostics = []
      @diagnostics_truncated = 0
    end

    def run
      base = analyze
      return finish(base) unless @apply && writable?(base)

      appended, locked = append_missing_under_lock(base[:missing_rows])
      locked[:appended] = appended
      return finish(locked) unless locked[:fatal].empty? && locked[:conflict_rows].empty?

      post = analyze
      post[:appended] = appended
      finish(post)
    end

    private

    def analyze
      reset_diagnostics
      canonical = load_canonical(@canonical)
      sources = discover_sources(@sources, @canonical)
      source_rows = sources[:rows]
      conflict_rows = sources[:conflicts]
      missing_rows = []
      present = 0

      unless canonical[:fatal].empty? || source_rows.empty?
        return analysis(canonical, sources, present, missing_rows, conflict_rows)
      end

      source_rows.each do |row|
        match = find_match(row, canonical[:recoverable])
        if match.nil?
          missing_rows << row
          diagnostic("missing #{identity_label(row)} at #{row.path}:#{row.line}")
        elsif rows_payload_equal?(row, match)
          present += 1
        else
          conflict_rows << [row, match]
          diagnostic("identity conflict #{identity_label(row)} at #{row.path}:#{row.line} vs #{match.path}:#{match.line}")
        end
      end

      analysis(canonical, sources, present, missing_rows, conflict_rows)
    end

    def analysis(canonical, sources, present, missing_rows, conflict_rows)
      {
        canonical_rows: canonical[:rows],
        families: canonical[:families],
        recoverable: canonical[:recoverable],
        sources: sources[:summary],
        fatal: canonical[:fatal] + sources[:fatal],
        present: present,
        missing_rows: dedupe_rows(missing_rows),
        conflict_rows: conflict_rows,
        open_starts: canonical[:open_starts],
        appended: 0
      }
    end

    def finish(state)
      state[:fatal].each { |message| diagnostic(message) }
      status =
        if state[:fatal].any?
          "corrupt"
        elsif state[:conflict_rows].any?
          "conflict"
        elsif state[:missing_rows].any?
          "drift"
        else
          "clean"
        end

      report = {
        schema: SCHEMA,
        command: @command,
        status: status,
        canonical: @canonical,
        canonical_rows: state[:canonical_rows],
        families: state[:families],
        sources: state[:sources],
        present: state[:present],
        missing: state[:missing_rows].length,
        conflicts: state[:conflict_rows].length,
        open_starts: state[:open_starts],
        appended: state[:appended],
        diagnostics: @diagnostics,
        diagnostics_truncated: @diagnostics_truncated
      }
      Result.new(report: report, exitstatus: status == "clean" ? 0 : 1)
    end

    def writable?(state) = state[:fatal].empty? && state[:conflict_rows].empty? && state[:missing_rows].any?

    def load_canonical(path)
      rows = []
      fatal = []
      families = FAMILY_KEYS.to_h { |key| [key, 0] }
      starts = {}
      ends = {}
      recoverable = []

      read_jsonl(path).each do |entry|
        if entry[:error]
          fatal << "malformed canonical JSON at #{path}:#{entry[:line]}"
          next
        end
        record = entry[:record]
        rows << record
        unless record.is_a?(Hash)
          fatal << "canonical JSON object required at #{path}:#{entry[:line]}"
          next
        end

        case canonical_family(record)
        when :v2_start
          families["v2_start"] += 1
          validate_v2(record, path, entry[:line], fatal) do |identity|
            add_unique(starts, identity, record, path, entry[:line], fatal, "v2 start")
          end
        when :v2_end
          families["v2_end"] += 1
          validate_v2(record, path, entry[:line], fatal) do |identity|
            add_unique(ends, identity, record, path, entry[:line], fatal, "v2 end")
            recoverable << build_row(record, path, entry[:line], :v2)
          end
        when :v1_end
          families["v1_end"] += 1
        when :legacy_rich
          families["legacy_rich"] += 1
          recoverable << build_row(record, path, entry[:line], :legacy)
        else
          families["legacy_unknown"] += 1
          diagnostic("legacy_unknown at #{path}:#{entry[:line]}")
        end
      end

      ends.each do |identity, row|
        fatal << "unpaired v2 end #{identity.join('|')} at #{row.path}:#{row.line}" unless starts.key?(identity)
      end

      {
        rows: rows.length,
        families: families,
        recoverable: recoverable,
        fatal: fatal,
        open_starts: (starts.keys - ends.keys).length
      }
    end

    def validate_v2(record, path, line, fatal)
      unless record["schema_version"] == Harnex::DispatchHistory::SCHEMA_VERSION
        fatal << "invalid v2 schema_version at #{path}:#{line}"
        return
      end
      id = record["id"].to_s
      session_id = record["session_id"].to_s
      started_at = normalized_time(record["started_at"])
      if id.empty? || session_id.empty? || started_at.nil?
        fatal << "invalid v2 identity at #{path}:#{line}"
        return
      end

      yield(["v2", session_id, id, started_at])
    end

    def add_unique(index, identity, record, path, line, fatal, label)
      prior = index[identity]
      if prior
        kind = payload_equal?(record, prior.record) ? "duplicate v2 identity" : "identity conflict"
        fatal << "#{kind} for #{label} #{identity.join('|')} at #{path}:#{line}"
        return
      end

      index[identity] = Row.new(record: record, path: path, line: line)
    end

    def discover_sources(paths, canonical_path)
      unique = paths.map { |path| File.expand_path(path) }.uniq
      files = unique.flat_map { |path| source_files(path, canonical_path) }
      rows = []
      fatal = []

      files.each do |file|
        parsed = parse_source_file(file[:path], explicit: file[:explicit])
        fatal.concat(parsed[:fatal])
        rows.concat(parsed[:rows])
      end

      conflicts = source_conflicts(rows)
      conflicts.each { |left, right| diagnostic("identity conflict #{identity_label(left)} at #{left.path}:#{left.line} vs #{right.path}:#{right.line}") }

      {
        rows: dedupe_source_rows(rows),
        fatal: fatal,
        summary: {
          "paths" => unique.length,
          "files_scanned" => files.length,
          "candidates" => rows.length
        },
        conflicts: conflicts
      }
    end

    def source_files(path, canonical_path)
      canonical_real = realpath_or_expand(canonical_path)
      if File.file?(path) && !File.symlink?(path)
        return [{ path: path, explicit: true }]
      end
      return [] unless File.directory?(path)

      files = []
      Dir.children(path).sort.each do |child|
        child_path = File.join(path, child)
        next if child == ".git" || File.symlink?(child_path)

        if File.directory?(child_path)
          files.concat(source_files(child_path, canonical_path))
        elsif File.file?(child_path) && child_path.match?(/\.(jsonl?|JSONL?)\z/)
          next if realpath_or_expand(child_path) == canonical_real

          files << { path: child_path, explicit: false }
        end
      end
      files
    end

    def parse_source_file(path, explicit:)
      parsed = parse_whole_json(path)
      entries = parsed ? json_entries(parsed, path) : read_jsonl(path)
      errors = entries.select { |entry| entry[:error] }
      rows = entries.filter_map do |entry|
        next if entry[:error]

        source_candidate(entry[:record], path, entry[:line])
      end

      fatal = []
      if explicit && errors.any?
        fatal << "malformed source telemetry at #{path}:#{errors.first[:line]}"
      elsif !explicit && rows.any? && errors.any?
        fatal << "malformed source telemetry at #{path}:#{errors.first[:line]}"
      end
      { rows: rows, fatal: fatal }
    end

    def parse_whole_json(path)
      text = File.read(path)
      return nil if text.strip.empty?

      JSON.parse(text)
    rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES
      nil
    end

    def json_entries(value, path)
      records = value.is_a?(Array) ? value : [value]
      records.each_with_index.map { |record, index| { record: record, line: index + 1, path: path } }
    end

    def read_jsonl(path)
      return [] unless File.file?(path)

      File.readlines(path, chomp: true).each_with_index.filter_map do |line, index|
        next if line.strip.empty?

        begin
          { record: JSON.parse(line), line: index + 1, path: path }
        rescue JSON::ParserError => error
          { error: error, line: index + 1, path: path }
        end
      end
    end

    def canonical_family(record)
      if record["schema_version"] == 2 && record["record_type"] == "dispatch_start"
        :v2_start
      elsif record["schema_version"] == 2 && record["record_type"] == "dispatch_end"
        :v2_end
      elsif record["schema_version"] == 1 && record.key?("status") && !record.key?("record_type")
        :v1_end
      elsif legacy_rich?(record)
        :legacy_rich
      else
        :legacy_unknown
      end
    end

    def source_candidate(record, path, line)
      if v2_rich_end?(record)
        build_row(record, path, line, :v2)
      elsif legacy_rich?(record)
        build_row(record, path, line, :legacy)
      end
    end

    def v2_rich_end?(record)
      record.is_a?(Hash) &&
        record["schema_version"] == 2 &&
        record["record_type"] == "dispatch_end" &&
        !record["id"].to_s.empty? &&
        !record["session_id"].to_s.empty? &&
        normalized_time(record["started_at"]) &&
        record["actual"].is_a?(Hash)
    end

    def legacy_rich?(record)
      return false unless record.is_a?(Hash)

      meta = record["meta"]
      rich_key_count = legacy_rich_key_count(record)
      meta.is_a?(Hash) &&
        !meta["id"].to_s.empty? &&
        normalized_time(meta["started_at"]) &&
        record["actual"].is_a?(Hash) &&
        (rich_key_count >= 2 || meta["harness"] == "harnex" && rich_key_count.positive?)
    end

    def build_row(record, path, line, family)
      id = family == :v2 ? record["id"].to_s : record.dig("meta", "id").to_s
      started_at = normalized_time(family == :v2 ? record["started_at"] : record.dig("meta", "started_at"))
      session_id = family == :v2 ? record["session_id"].to_s : nil
      identity = family == :v2 ? ["v2", session_id, id, started_at] : ["legacy", id, started_at]
      Row.new(
        record: record,
        path: path,
        line: line,
        family: family,
        identity: identity,
        match_identity: [id, started_at],
        sort_key: [started_at, path, line]
      )
    end

    def find_match(row, canonical_rows)
      same_family = canonical_rows.find { |candidate| candidate.identity == row.identity }
      return same_family if same_family

      canonical_rows.find { |candidate| candidate.match_identity == row.match_identity }
    end

    def source_conflicts(rows)
      conflicts = []
      rows.group_by(&:identity).each_value do |group|
        first = group.first
        group.drop(1).each { |row| conflicts << [first, row] unless payload_equal?(first.record, row.record) }
      end
      rows.group_by(&:match_identity).each_value do |group|
        next unless group.map(&:family).uniq.length > 1

        group.combination(2) do |left, right|
          next if left.family == right.family

          conflicts << [left, right] unless rows_payload_equal?(left, right)
        end
      end
      conflicts
    end

    def dedupe_source_rows(rows)
      selected = []
      rows.sort_by { |row| [row.sort_key[0], row.match_identity, family_preference(row), row.path, row.line] }.each do |row|
        next if selected.any? { |candidate| candidate.identity == row.identity }

        match = selected.find { |candidate| candidate.family != row.family && candidate.match_identity == row.match_identity }
        next if match && rows_payload_equal?(match, row)

        selected << row
      end
      selected
    end

    def dedupe_rows(rows)
      seen = Set.new
      rows.sort_by(&:sort_key).select do |row|
        key = row.identity
        next false if seen.include?(key)

        seen << key
        true
      end
    end

    def legacy_rich_key_count(record) = (RICH_KEYS & record.keys).length

    def family_preference(row) = row.family == :legacy ? 0 : 1

    def append_missing_under_lock(rows)
      FileUtils.mkdir_p(File.dirname(@canonical))
      File.open(@canonical, File::RDWR | File::CREAT, 0o644) do |file|
        file.flock(File::LOCK_EX)
        file.rewind
        existing = file.read
        locked = analyze
        return [0, locked] unless writable?(locked)

        still_missing = locked[:missing_rows].select { |row| rows.any? { |wanted| wanted.identity == row.identity } }
        payload = still_missing.map { |row| JSON.generate(row.record) }.join("\n")
        payload = "\n#{payload}" unless existing.empty? || existing.end_with?("\n")
        payload = "#{payload}\n" unless payload.empty?
        file.seek(0, IO::SEEK_END)
        file.write(payload)
        file.flush
        [still_missing.length, locked.merge(missing_rows: [])]
      ensure
        file.flock(File::LOCK_UN) unless file.closed?
      end
    end

    def payload_equal?(left, right) = deep_normalize(left) == deep_normalize(right)

    def rows_payload_equal?(left, right)
      if left.family != right.family
        comparable_rich_payload(left.record) == comparable_rich_payload(right.record)
      else
        payload_equal?(left.record, right.record)
      end
    end

    def comparable_rich_payload(record)
      keys = ["meta", "actual"] + RICH_KEYS
      deep_normalize(record.select { |key, _value| keys.include?(key) })
    end

    def deep_normalize(value)
      case value
      when Hash
        value.keys.sort.to_h do |key|
          normalized =
            if key == "started_at"
              normalized_time(value[key]) || value[key]
            else
              deep_normalize(value[key])
            end
          [key, normalized]
        end
      when Array
        value.map { |item| deep_normalize(item) }
      else
        value
      end
    end

    def normalized_time(value)
      Time.iso8601(value.to_s).utc.iso8601
    rescue ArgumentError
      nil
    end

    def realpath_or_expand(path)
      File.realpath(path)
    rescue Errno::ENOENT, Errno::EACCES
      File.expand_path(path)
    end

    def identity_label(row) = row.identity.join("|")

    def reset_diagnostics
      @diagnostics = []
      @diagnostics_truncated = 0
    end

    def diagnostic(message)
      if @diagnostics.length < MAX_DIAGNOSTICS
        @diagnostics << message
      else
        @diagnostics_truncated += 1
      end
    end
  end
end
