require "digest"
require "fileutils"
require "json"
require "time"

module Harnex
  module ArtifactReport
    SCHEMA = "harnex.artifact_report.v1"
    MAX_BYTES = 256 * 1024
    MAX_ARTIFACTS = 50
    MAX_COMMANDS = 50
    MAX_CANONICAL_ARTIFACTS = 50
    MAX_EVIDENCE_ITEMS = 20
    MAX_STRING_LENGTH = 2_000
    MAX_DIAGNOSTICS = 100
    MAX_CHANGED_PATHS = 200
    RECEIPT_VERSION = 1
    CLAIM_SEVERITIES = %w[P1 P2 P3].freeze
    COMMAND_OBSERVATION_STATUSES = %w[observed unsupported].freeze
    GIT_OBSERVATION_STATUSES = %w[observed unavailable].freeze
    USAGE_STATUSES = %w[observed estimated unsupported missing zero].freeze

    REPORT_STATUSES = %w[in_progress pass fail blocked unknown].freeze
    VALIDATION_STATUSES = %w[in_progress pass fail not_run unknown].freeze
    OUTCOME_STATUSES = %w[accepted rejected no_change unknown].freeze
    ACCEPTED_OUTCOME_STATUSES = %w[accepted no_change].freeze

    ValidationResult = Struct.new(
      :ok, :status, :path, :bytes, :sha256, :schema, :diagnostics, :report,
      keyword_init: true
    ) do
      def public_payload(final: false)
        {
          "ok" => !!ok,
          "status" => status,
          "path" => path,
          "bytes" => bytes,
          "sha256" => sha256,
          "schema" => schema,
          "final" => !!final,
          "diagnostics" => diagnostics || []
        }
      end
    end

    module_function

    def validate(path, final: false)
      report_path = File.expand_path(path.to_s)
      return validation_failure(
        report_path,
        status: "missing",
        diagnostics: [diagnostic("report_missing", "$", "artifact report file does not exist")]
      ) unless File.file?(report_path)

      bytes = File.size(report_path)
      sha256 = file_sha256(report_path)
      if bytes > MAX_BYTES
        return validation_failure(
          report_path,
          status: "oversized",
          bytes: bytes,
          sha256: sha256,
          diagnostics: [
            diagnostic("report_oversized", "$", "artifact report exceeds the #{MAX_BYTES}-byte limit")
          ]
        )
      end

      parsed = JSON.parse(File.read(report_path, mode: "rb"))
      unless parsed.is_a?(Hash)
        return validation_failure(
          report_path,
          status: "malformed",
          bytes: bytes,
          sha256: sha256,
          diagnostics: [diagnostic("object_required", "$", "artifact report must be a JSON object")]
        )
      end

      schema = parsed["schema"].is_a?(String) ? bounded_string(parsed["schema"]) : nil
      diagnostics = validate_document(parsed, final: final)
      status = if parsed["schema"] != SCHEMA
                 "unsupported_schema"
               elsif diagnostics.empty?
                 "valid"
               else
                 "invalid"
               end

      ValidationResult.new(
        ok: diagnostics.empty?,
        status: status,
        path: report_path,
        bytes: bytes,
        sha256: sha256,
        schema: schema,
        diagnostics: diagnostics,
        report: parsed
      )
    rescue JSON::ParserError
      validation_failure(
        report_path,
        status: "malformed",
        bytes: safe_file_size(report_path),
        sha256: safe_file_sha256(report_path),
        diagnostics: [diagnostic("json_invalid", "$", "artifact report is not valid JSON")]
      )
    rescue StandardError
      validation_failure(
        report_path,
        status: "error",
        bytes: safe_file_size(report_path),
        sha256: safe_file_sha256(report_path),
        diagnostics: [diagnostic("read_error", "$", "artifact report could not be read")]
      )
    end

    def ingest(path)
      result = validate(path)
      case result.status
      when "missing"
        missing(result.path)
      when "oversized"
        warning(
          result.path,
          bytes: result.bytes,
          sha256: result.sha256,
          ingest_status: "oversized",
          warning: "artifact report is #{result.bytes} bytes; max is #{MAX_BYTES} bytes",
          diagnostics: result.diagnostics
        )
      when "malformed"
        warning(
          result.path,
          bytes: result.bytes,
          sha256: result.sha256,
          ingest_status: "malformed",
          warning: "malformed artifact report JSON",
          diagnostics: result.diagnostics
        )
      when "unsupported_schema"
        warning(
          result.path,
          bytes: result.bytes,
          sha256: result.sha256,
          ingest_status: "unsupported_schema",
          schema: result.schema,
          warning: "unsupported artifact report schema; expected #{SCHEMA}",
          diagnostics: result.diagnostics
        )
      when "error"
        warning(
          result.path,
          bytes: result.bytes,
          sha256: result.sha256,
          ingest_status: "error",
          warning: "artifact report ingest failed",
          diagnostics: result.diagnostics
        )
      else
        payload = build_payload(
          result.path,
          bytes: result.bytes,
          sha256: result.sha256,
          report: result.report
        )
        unless result.ok
          metadata = payload.fetch("artifact_report")
          metadata["ingest_status"] = "invalid"
          metadata["warning"] = "artifact report does not conform to #{SCHEMA}"
          metadata["diagnostics"] = result.diagnostics
        end
        payload
      end
    end

    def initialize_file(path, force: false)
      report_path = File.expand_path(path.to_s)
      raise ArgumentError, "artifact report path is required" if path.to_s.strip.empty?
      if File.exist?(report_path) && !force
        raise ArgumentError, "artifact report already exists: #{report_path} (use --force to replace it)"
      end

      FileUtils.mkdir_p(File.dirname(report_path))
      File.write(report_path, JSON.pretty_generate(template) + "\n")
      report_path
    end

    def template
      {
        "schema" => SCHEMA,
        "status" => "in_progress",
        "canonical_artifacts" => [],
        "outcome" => {
          "status" => "unknown",
          "summary" => ""
        },
        "validation" => {
          "status" => "not_run",
          "commands" => [],
          "final_reported" => false
        },
        "artifacts" => []
      }
    end

    # Default receipts live outside the checkout so proof generation cannot
    # become part of the Git delta it is recording. An explicit
    # --artifact-report path still wins for callers that need a stable path.
    def default_path(repo_root:, id:, session_id:)
      slug = Harnex.id_key(id)
      slug = Digest::SHA256.hexdigest(id.to_s)[0, 12] if slug.empty?
      File.join(
        Harnex::STATE_DIR,
        "receipts",
        "#{Harnex.repo_key(repo_root)}-#{slug}-#{session_id}.json"
      )
    end

    def claims_path(report_path)
      "#{File.expand_path(report_path.to_s)}.claims.json"
    end

    # Claims are deliberately advisory. Malformed, stale, or oversized claims
    # are ignored by Session and can never invalidate observed proof.
    def extract_claims(path)
      claims_path = File.expand_path(path.to_s)
      return {} unless File.file?(claims_path)
      return {} if File.size(claims_path) > MAX_BYTES

      document = JSON.parse(File.read(claims_path, mode: "rb"))
      return {} unless document.is_a?(Hash)

      source = document["claims"].is_a?(Hash) ? document["claims"] : document
      claims = compact_claims(source)

      # Compatibility bridge for old worker-authored v1 reports. Their
      # outcome is retained only as an untrusted verdict/summary claim; it no
      # longer participates in completion acceptance.
      if claims.empty? && document["schema"] == SCHEMA
        outcome = document["outcome"]
        if outcome.is_a?(Hash)
          claims = compact_claims(
            "summary" => outcome["summary"],
            "verdict" => outcome["status"]
          )
        end
      end
      claims
    rescue StandardError
      {}
    end

    def build_observed(
      id:, session_id:, generated_at:, successful:, outcome_status:,
      outcome_summary:, git:, commands:, turn:, usage:, claims:,
      command_observation:
    )
      observed_commands = compact_commands(commands).select do |entry|
        non_empty_string?(entry["cmd"]) && entry["exit_code"].is_a?(Integer)
      end
      git_payload = compact_observed_git(git)
      turn_payload = compact_observed_turn(turn)
      usage_payload = compact_observed_usage(usage)
      claims_payload = compact_claims(claims)
      validation_status = if observed_commands.empty?
                            "not_run"
                          elsif observed_commands.all? { |entry| entry["exit_code"].zero? }
                            "pass"
                          else
                            "fail"
                          end
      start_sha = git_payload["start_sha"].to_s
      end_sha = git_payload["end_sha"].to_s
      commit_sha = end_sha unless start_sha.empty? || end_sha.empty? || start_sha == end_sha

      report = {
        "schema" => SCHEMA,
        "status" => successful ? "pass" : "fail",
        "canonical_artifacts" => [],
        "outcome" => {
          "status" => outcome_status,
          "summary" => bounded_string(outcome_summary),
          "commit_sha" => commit_sha
        }.compact,
        "validation" => {
          "status" => validation_status,
          "commands" => observed_commands,
          "final_reported" => true
        },
        "artifacts" => [],
        "receipt" => {
          "version" => RECEIPT_VERSION,
          "author" => "harnex",
          "generated_at" => generated_at.respond_to?(:iso8601) ? generated_at.iso8601 : generated_at.to_s,
          "id" => bounded_string(id),
          "session_id" => bounded_string(session_id)
        },
        "observed" => {
          "git" => git_payload,
          "commands" => observed_commands,
          "command_observation" => command_observation.to_s,
          "turn" => turn_payload,
          "usage" => usage_payload
        }
      }
      report["claims"] = claims_payload unless claims_payload.empty?
      fit_observed_report!(report)
    end

    def fit_observed_report!(report)
      loop do
        return report if JSON.pretty_generate(report).bytesize + 1 <= MAX_BYTES

        commands = report.dig("observed", "commands")
        if commands.is_a?(Array) && !commands.empty?
          commands.pop
          report.dig("observed")["commands_truncated"] = true
          next
        end

        paths = report.dig("observed", "git", "changed_paths")
        if paths.is_a?(Array) && !paths.empty?
          paths.pop
          report.dig("observed", "git")["changed_paths_truncated"] = true
          next
        end

        raise ArgumentError, "generated artifact receipt exceeds the #{MAX_BYTES}-byte limit"
      end
    end

    def write_observed(path, **attributes)
      report_path = File.expand_path(path.to_s)
      report = build_observed(**attributes)
      diagnostics = validate_document(report)
      unless diagnostics.empty?
        raise ArgumentError, "generated artifact receipt is invalid: #{diagnostics.first.fetch('path')}"
      end

      FileUtils.mkdir_p(File.dirname(report_path))
      temporary_path = "#{report_path}.tmp.#{Process.pid}.#{Thread.current.object_id}"
      File.open(temporary_path, "wb", 0o644) do |file|
        file.write(JSON.pretty_generate(report))
        file.write("\n")
        file.flush
        file.fsync
      end
      File.rename(temporary_path, report_path)

      result = validate(report_path, final: !!attributes[:successful])
      if attributes[:successful] && !accepted_final?(result)
        raise ArgumentError, "generated artifact receipt did not satisfy final validation"
      end
      result
    ensure
      FileUtils.rm_f(temporary_path) if defined?(temporary_path) && temporary_path
    end

    def accepted_final?(result)
      result.ok && ACCEPTED_OUTCOME_STATUSES.include?(outcome_status(result))
    end

    def fingerprint(path)
      report_path = File.expand_path(path.to_s)
      return nil unless File.file?(report_path)

      stat = File.stat(report_path)
      {
        "bytes" => stat.size,
        "sha256" => file_sha256(report_path),
        "mtime_ns" => (stat.mtime.to_r * 1_000_000_000).to_i,
        "ctime_ns" => (stat.ctime.to_r * 1_000_000_000).to_i,
        "inode" => stat.ino
      }
    rescue StandardError
      nil
    end

    def outcome_status(result)
      report = result.respond_to?(:report) ? result.report : result
      return nil unless report.is_a?(Hash)

      outcome = report["outcome"]
      outcome.is_a?(Hash) ? outcome["status"] : nil
    end

    def validate_document(report, final: false)
      diagnostics = []
      validate_schema(report, diagnostics)
      validate_optional_enum(report, "status", REPORT_STATUSES, diagnostics)
      validate_string_array_field(
        report,
        "canonical_artifacts",
        max_items: MAX_CANONICAL_ARTIFACTS,
        diagnostics: diagnostics
      )
      validate_outcome(report["outcome"], diagnostics) if report.key?("outcome")
      validate_validation(report["validation"], diagnostics) if report.key?("validation")
      validate_artifacts(report["artifacts"], diagnostics) if report.key?("artifacts")
      validate_receipt(report["receipt"], diagnostics) if report.key?("receipt")
      validate_observed(report["observed"], diagnostics) if report.key?("observed")
      # `claims` is intentionally not part of validity. Session emits only a
      # bounded sanitized subset, while malformed worker claims are ignored.
      validate_final_contract(report, diagnostics) if final
      diagnostics.first(MAX_DIAGNOSTICS)
    end

    def validate_schema(report, diagnostics)
      value = report["schema"]
      if !value.is_a?(String) || value.empty?
        diagnostics << diagnostic("schema_required", "$.schema", "schema must be a non-empty string")
      elsif value != SCHEMA
        diagnostics << diagnostic("schema_unsupported", "$.schema", "schema must equal #{SCHEMA}")
      end
    end

    def validate_optional_enum(report, key, values, diagnostics)
      return unless report.key?(key)

      value = report[key]
      unless value.is_a?(String) && values.include?(value)
        diagnostics << diagnostic("enum", "$.#{key}", "#{key} must be one of #{values.join(', ')}")
      end
    end

    def validate_outcome(value, diagnostics)
      unless value.is_a?(Hash)
        diagnostics << diagnostic("object_required", "$.outcome", "outcome must be an object")
        return
      end

      status = value["status"]
      unless status.is_a?(String) && OUTCOME_STATUSES.include?(status)
        diagnostics << diagnostic(
          "enum",
          "$.outcome.status",
          "outcome.status must be one of #{OUTCOME_STATUSES.join(', ')}"
        )
      end
      validate_optional_string(value, "summary", "$.outcome.summary", diagnostics)
      validate_optional_string(value, "commit_sha", "$.outcome.commit_sha", diagnostics)
    end

    def validate_validation(value, diagnostics)
      unless value.is_a?(Hash)
        diagnostics << diagnostic("object_required", "$.validation", "validation must be an object")
        return
      end

      if value.key?("status")
        status = value["status"]
        unless status.is_a?(String) && VALIDATION_STATUSES.include?(status)
          diagnostics << diagnostic(
            "enum",
            "$.validation.status",
            "validation.status must be one of #{VALIDATION_STATUSES.join(', ')}"
          )
        end
      end

      validate_commands(value["commands"], diagnostics) if value.key?("commands")
      if value.key?("final_reported") && !boolean?(value["final_reported"])
        diagnostics << diagnostic(
          "boolean_required",
          "$.validation.final_reported",
          "validation.final_reported must be true or false"
        )
      end
    end

    def validate_commands(value, diagnostics, base_path: "$.validation.commands")
      unless value.is_a?(Array)
        diagnostics << diagnostic("array_required", base_path, "#{base_path.delete_prefix('$.')} must be an array")
        return
      end
      if value.length > MAX_COMMANDS
        diagnostics << diagnostic(
          "too_many_items",
          base_path,
          "#{base_path.delete_prefix('$.')} may contain at most #{MAX_COMMANDS} entries"
        )
      end

      value.first(MAX_COMMANDS).each_with_index do |entry, index|
        path = "#{base_path}[#{index}]"
        unless entry.is_a?(Hash)
          diagnostics << diagnostic("object_required", path, "validation command must be an object")
          next
        end

        validate_required_string(entry, "cmd", "#{path}.cmd", diagnostics)
        unless entry["exit_code"].is_a?(Integer)
          diagnostics << diagnostic(
            "integer_required",
            "#{path}.exit_code",
            "validation command exit_code must be an integer"
          )
        end
        validate_optional_string(entry, "status", "#{path}.status", diagnostics)
        if entry.key?("duration_s") && !finite_non_negative_number?(entry["duration_s"])
          diagnostics << diagnostic(
            "number_required",
            "#{path}.duration_s",
            "validation command duration_s must be a finite non-negative number"
          )
        end
      end
    end

    def validate_artifacts(value, diagnostics)
      unless value.is_a?(Array)
        diagnostics << diagnostic("array_required", "$.artifacts", "artifacts must be an array")
        return
      end
      if value.length > MAX_ARTIFACTS
        diagnostics << diagnostic(
          "too_many_items",
          "$.artifacts",
          "artifacts may contain at most #{MAX_ARTIFACTS} entries"
        )
      end

      value.first(MAX_ARTIFACTS).each_with_index do |entry, index|
        path = "$.artifacts[#{index}]"
        unless entry.is_a?(Hash)
          diagnostics << diagnostic("object_required", path, "artifact must be an object")
          next
        end

        validate_required_string(entry, "type", "#{path}.type", diagnostics)
        validate_required_string(entry, "summary", "#{path}.summary", diagnostics)
        validate_string_array_value(
          entry["evidence"],
          "#{path}.evidence",
          max_items: MAX_EVIDENCE_ITEMS,
          diagnostics: diagnostics,
          required: true
        )
        confidence = entry["confidence"]
        unless finite_number?(confidence) && confidence >= 0.0 && confidence <= 1.0
          diagnostics << diagnostic(
            "range",
            "#{path}.confidence",
            "artifact confidence must be a finite number from 0 through 1"
          )
        end
        validate_optional_string(entry, "canonical_ref", "#{path}.canonical_ref", diagnostics)
      end
    end

    def validate_receipt(value, diagnostics)
      unless value.is_a?(Hash)
        diagnostics << diagnostic("object_required", "$.receipt", "receipt must be an object")
        return
      end

      unless value["version"] == RECEIPT_VERSION
        diagnostics << diagnostic("receipt_version", "$.receipt.version", "receipt.version must equal #{RECEIPT_VERSION}")
      end
      unless value["author"] == "harnex"
        diagnostics << diagnostic("receipt_author", "$.receipt.author", "receipt.author must equal harnex")
      end
      validate_required_string(value, "generated_at", "$.receipt.generated_at", diagnostics)
      begin
        Time.iso8601(value["generated_at"].to_s)
      rescue ArgumentError
        diagnostics << diagnostic("timestamp_required", "$.receipt.generated_at", "receipt.generated_at must be ISO 8601")
      end
      validate_required_string(value, "id", "$.receipt.id", diagnostics)
      validate_required_string(value, "session_id", "$.receipt.session_id", diagnostics)
    end

    def validate_observed(value, diagnostics)
      unless value.is_a?(Hash)
        diagnostics << diagnostic("object_required", "$.observed", "observed must be an object")
        return
      end

      git = value["git"]
      unless git.is_a?(Hash)
        diagnostics << diagnostic("object_required", "$.observed.git", "observed.git must be an object")
      else
        unless GIT_OBSERVATION_STATUSES.include?(git["status"])
          diagnostics << diagnostic("enum", "$.observed.git.status", "observed.git.status must be observed or unavailable")
        end
        %w[start_sha end_sha branch].each do |key|
          validate_optional_string(git, key, "$.observed.git.#{key}", diagnostics)
        end
        if git["status"] == "observed"
          %w[start_sha end_sha].each do |key|
            unless git[key].is_a?(String) && git[key].match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
              diagnostics << diagnostic("git_sha", "$.observed.git.#{key}", "observed.git.#{key} must be a full hexadecimal Git SHA")
            end
          end
        end
        validate_string_array_value(
          git["changed_paths"],
          "$.observed.git.changed_paths",
          max_items: MAX_CHANGED_PATHS,
          diagnostics: diagnostics,
          required: true
        ) if git["status"] == "observed" || git.key?("changed_paths")
        %w[loc_added loc_removed files_changed commits].each do |key|
          if git["status"] == "observed" && !git.key?(key)
            diagnostics << diagnostic("required", "$.observed.git.#{key}", "observed.git.#{key} is required when Git is observed")
            next
          end
          next unless git.key?(key)
          next if git[key].is_a?(Integer) && git[key] >= 0

          diagnostics << diagnostic("integer_required", "$.observed.git.#{key}", "observed.git.#{key} must be a non-negative integer")
        end
        %w[start_dirty end_dirty worktree_changed changed_paths_truncated].each do |key|
          next unless git.key?(key)
          next if boolean?(git[key])

          diagnostics << diagnostic("boolean_required", "$.observed.git.#{key}", "observed.git.#{key} must be true or false")
        end
      end

      validate_commands(value["commands"], diagnostics, base_path: "$.observed.commands")
      if value.key?("commands_truncated") && !boolean?(value["commands_truncated"])
        diagnostics << diagnostic("boolean_required", "$.observed.commands_truncated", "observed.commands_truncated must be true or false")
      end
      unless COMMAND_OBSERVATION_STATUSES.include?(value["command_observation"])
        diagnostics << diagnostic(
          "enum",
          "$.observed.command_observation",
          "observed.command_observation must be observed or unsupported"
        )
      end

      turn = value["turn"]
      unless turn.is_a?(Hash)
        diagnostics << diagnostic("object_required", "$.observed.turn", "observed.turn must be an object")
      else
        validate_required_string(turn, "status", "$.observed.turn.status", diagnostics)
        %w[task_complete task_failed accepted].each do |key|
          next if boolean?(turn[key])

          diagnostics << diagnostic("boolean_required", "$.observed.turn.#{key}", "observed.turn.#{key} must be true or false")
        end
        validate_optional_string(turn, "outcome_class", "$.observed.turn.outcome_class", diagnostics)
        if turn.key?("exit_code") && !turn["exit_code"].is_a?(Integer)
          diagnostics << diagnostic("integer_required", "$.observed.turn.exit_code", "observed.turn.exit_code must be an integer")
        end
      end

      unless value["usage"].is_a?(Hash)
        diagnostics << diagnostic("object_required", "$.observed.usage", "observed.usage must be an object")
      else
        unless USAGE_STATUSES.include?(value.dig("usage", "status"))
          diagnostics << diagnostic("enum", "$.observed.usage.status", "observed.usage.status must be observed, estimated, unsupported, missing, or zero")
        end
      end
    end

    def validate_final_contract(report, diagnostics)
      if harness_receipt?(report)
        validate_observed_final_contract(report, diagnostics)
        return
      end

      unless report["status"] == "pass"
        diagnostics << diagnostic("final_status", "$.status", "final report status must be pass")
      end

      outcome = report["outcome"]
      unless outcome.is_a?(Hash)
        diagnostics << diagnostic("required", "$.outcome", "final report requires an outcome object")
      else
        unless ACCEPTED_OUTCOME_STATUSES.include?(outcome["status"])
          diagnostics << diagnostic(
            "outcome_not_accepted",
            "$.outcome.status",
            "final outcome must be accepted or no_change"
          )
        end
        unless non_empty_string?(outcome["summary"])
          diagnostics << diagnostic(
            "required",
            "$.outcome.summary",
            "final outcome requires a non-empty summary"
          )
        end
      end

      validation = report["validation"]
      unless validation.is_a?(Hash)
        diagnostics << diagnostic("required", "$.validation", "final report requires a validation object")
        return
      end

      expected_statuses = outcome.is_a?(Hash) && outcome["status"] == "no_change" ? %w[pass not_run] : %w[pass]
      unless expected_statuses.include?(validation["status"])
        diagnostics << diagnostic(
          "final_validation_status",
          "$.validation.status",
          "final validation.status must be #{expected_statuses.join(' or ')}"
        )
      end
      unless validation["commands"].is_a?(Array)
        diagnostics << diagnostic(
          "required",
          "$.validation.commands",
          "final report requires a validation.commands array"
        )
      end
      unless validation["final_reported"] == true
        diagnostics << diagnostic(
          "final_reported",
          "$.validation.final_reported",
          "final report requires validation.final_reported=true"
        )
      end

      Array(validation["commands"]).first(MAX_COMMANDS).each_with_index do |entry, index|
        next unless entry.is_a?(Hash) && entry["exit_code"].is_a?(Integer)
        next if entry["exit_code"].zero?

        diagnostics << diagnostic(
          "command_failed",
          "$.validation.commands[#{index}].exit_code",
          "accepted final reports require validation command exit_code=0"
        )
      end
    end

    def harness_receipt?(report)
      report.dig("receipt", "author") == "harnex"
    end

    # Harness receipts prove that the receipt itself is complete and that
    # Harnex accepted the observed terminal state. Individual command failures
    # remain factual telemetry: they are not treated as worker-authored gates,
    # because exploratory failures can precede a successful final turn.
    def validate_observed_final_contract(report, diagnostics)
      unless report["status"] == "pass"
        diagnostics << diagnostic("final_status", "$.status", "final receipt status must be pass")
      end

      outcome = report["outcome"]
      unless outcome.is_a?(Hash) && ACCEPTED_OUTCOME_STATUSES.include?(outcome["status"])
        diagnostics << diagnostic("outcome_not_accepted", "$.outcome.status", "final receipt outcome must be accepted or no_change")
      end
      unless outcome.is_a?(Hash) && non_empty_string?(outcome["summary"])
        diagnostics << diagnostic("required", "$.outcome.summary", "final receipt requires a non-empty summary")
      end

      validation = report["validation"]
      unless validation.is_a?(Hash) && validation["final_reported"] == true
        diagnostics << diagnostic("final_reported", "$.validation.final_reported", "final receipt requires validation.final_reported=true")
      end

      turn = report.dig("observed", "turn")
      unless turn.is_a?(Hash) && turn["accepted"] == true
        diagnostics << diagnostic("observed_not_accepted", "$.observed.turn.accepted", "final receipt requires an accepted observed turn")
      end

      return unless outcome.is_a?(Hash) && outcome["status"] == "no_change"

      git = report.dig("observed", "git")
      no_change = git.is_a?(Hash) &&
        git["status"] == "observed" &&
        git["commits"].to_i.zero? &&
        Array(git["changed_paths"]).empty? &&
        !git["start_sha"].to_s.empty? &&
        git["start_sha"].to_s == git["end_sha"].to_s
      unless no_change
        diagnostics << diagnostic(
          "no_change_unobserved",
          "$.observed.git",
          "no_change requires an observed zero-delta Git state"
        )
      end
    end

    def validate_string_array_field(report, key, max_items:, diagnostics:)
      return unless report.key?(key)

      validate_string_array_value(
        report[key],
        "$.#{key}",
        max_items: max_items,
        diagnostics: diagnostics,
        required: true
      )
    end

    def validate_string_array_value(value, path, max_items:, diagnostics:, required:)
      if value.nil? && !required
        return
      end
      unless value.is_a?(Array)
        diagnostics << diagnostic("array_required", path, "#{path.delete_prefix('$.')} must be an array")
        return
      end
      if value.length > max_items
        diagnostics << diagnostic("too_many_items", path, "#{path.delete_prefix('$.')} may contain at most #{max_items} entries")
      end

      value.first(max_items).each_with_index do |item, index|
        next if non_empty_string?(item)

        diagnostics << diagnostic(
          "string_required",
          "#{path}[#{index}]",
          "#{path.delete_prefix('$.')} entries must be non-empty strings"
        )
      end
    end

    def validate_required_string(hash, key, path, diagnostics)
      return if non_empty_string?(hash[key])

      diagnostics << diagnostic("string_required", path, "#{path.delete_prefix('$.')} must be a non-empty string")
    end

    def validate_optional_string(hash, key, path, diagnostics)
      return unless hash.key?(key)
      return if hash[key].is_a?(String) && hash[key].length <= MAX_STRING_LENGTH

      diagnostics << diagnostic(
        "string_required",
        path,
        "#{path.delete_prefix('$.')} must be a string no longer than #{MAX_STRING_LENGTH} characters"
      )
    end

    def build_payload(path, bytes:, sha256:, report:)
      artifacts = compact_artifacts(report["artifacts"])
      validation = compact_validation(report["validation"])
      outcome = compact_outcome(report["outcome"])
      receipt = compact_receipt(report["receipt"])
      observed = compact_observed(report["observed"])
      claims = compact_claims(report["claims"])
      payload = {
        "artifact_report" => metadata(
          path,
          bytes: bytes,
          sha256: sha256,
          ingest_status: "ok",
          schema: SCHEMA
        ).merge(
          "report_status" => bounded_string_or_nil(report["status"]),
          "canonical_artifacts" => string_array(report["canonical_artifacts"], max_items: MAX_CANONICAL_ARTIFACTS),
          "artifact_count" => artifacts.length,
          "author" => receipt&.dig("author")
        )
      }
      payload["validation"] = validation if validation
      payload["artifacts"] = artifacts unless artifacts.empty?
      payload["outcome"] = outcome if outcome
      payload["receipt"] = receipt if receipt
      payload["observed"] = observed if observed
      payload["claims"] = claims unless claims.empty?
      payload
    end

    def missing(path)
      warning(
        path,
        bytes: nil,
        sha256: nil,
        ingest_status: "missing",
        warning: "artifact report not found",
        diagnostics: [diagnostic("report_missing", "$", "artifact report file does not exist")]
      )
    end

    def warning(path, bytes:, sha256:, ingest_status:, warning:, schema: nil, diagnostics: nil)
      report = metadata(path, bytes: bytes, sha256: sha256, ingest_status: ingest_status, schema: schema)
      report["warning"] = bounded_string(warning)
      report["diagnostics"] = Array(diagnostics).first(MAX_DIAGNOSTICS) unless Array(diagnostics).empty?
      { "artifact_report" => report }
    end

    def metadata(path, bytes:, sha256:, ingest_status:, schema: nil)
      {
        "path" => path.to_s,
        "bytes" => bytes,
        "sha256" => sha256,
        "ingest_status" => ingest_status,
        "schema" => schema
      }
    end

    def compact_receipt(value)
      return nil unless value.is_a?(Hash)

      payload = {
        "version" => integer_or_nil(value["version"]),
        "author" => bounded_string_or_nil(value["author"]),
        "generated_at" => bounded_string_or_nil(value["generated_at"]),
        "id" => bounded_string_or_nil(value["id"]),
        "session_id" => bounded_string_or_nil(value["session_id"])
      }
      payload.delete_if { |_key, item| item.nil? }
      payload.empty? ? nil : payload
    end

    def compact_observed(value)
      return nil unless value.is_a?(Hash)

      payload = {
        "git" => compact_observed_git(value["git"]),
        "commands" => compact_commands(value["commands"]),
        "commands_truncated" => boolean_or_nil(value["commands_truncated"]),
        "command_observation" => bounded_string_or_nil(value["command_observation"]),
        "turn" => compact_observed_turn(value["turn"]),
        "usage" => compact_observed_usage(value["usage"])
      }
      payload.delete_if { |_key, item| item.nil? }
      payload.empty? ? nil : payload
    end

    def compact_observed_git(value)
      value = {} unless value.is_a?(Hash)
      status = hash_value(value, "status").to_s
      status = "observed" if status.empty? && !hash_value(value, "start_sha").to_s.empty?
      status = "unavailable" unless GIT_OBSERVATION_STATUSES.include?(status)
      payload = {
        "status" => status,
        "start_sha" => bounded_string_or_nil(hash_value(value, "start_sha")),
        "end_sha" => bounded_string_or_nil(hash_value(value, "end_sha")),
        "branch" => bounded_string_or_nil(hash_value(value, "branch")),
        "changed_paths" => string_array(hash_value(value, "changed_paths"), max_items: MAX_CHANGED_PATHS),
        "loc_added" => non_negative_integer_or_nil(hash_value(value, "loc_added")),
        "loc_removed" => non_negative_integer_or_nil(hash_value(value, "loc_removed")),
        "files_changed" => non_negative_integer_or_nil(hash_value(value, "files_changed")),
        "commits" => non_negative_integer_or_nil(hash_value(value, "commits")),
        "start_dirty" => boolean_or_nil(hash_value(value, "start_dirty")),
        "end_dirty" => boolean_or_nil(hash_value(value, "end_dirty")),
        "worktree_changed" => boolean_or_nil(hash_value(value, "worktree_changed")),
        "changed_paths_truncated" => boolean_or_nil(hash_value(value, "changed_paths_truncated"))
      }
      payload.delete_if { |key, item| item.nil? || (key == "changed_paths" && status == "unavailable") }
      payload
    end

    def compact_observed_turn(value)
      value = {} unless value.is_a?(Hash)
      payload = {
        "status" => bounded_string_or_nil(hash_value(value, "status")),
        "outcome_class" => bounded_string_or_nil(hash_value(value, "outcome_class")),
        "task_complete" => !!hash_value(value, "task_complete"),
        "task_failed" => !!hash_value(value, "task_failed"),
        "accepted" => !!hash_value(value, "accepted"),
        "exit_code" => integer_or_nil(hash_value(value, "exit_code")),
        "signal" => integer_or_nil(hash_value(value, "signal"))
      }
      payload.delete_if { |_key, item| item.nil? }
      payload
    end

    def compact_observed_usage(value)
      value = {} unless value.is_a?(Hash)
      payload = {}
      %w[status cost_source cost_price_as_of].each do |key|
        payload[key] = bounded_string_or_nil(hash_value(value, key))
      end
      payload["cost_usd"] = finite_float_or_nil(hash_value(value, "cost_usd"))
      %w[input_tokens output_tokens cached_input_tokens reasoning_tokens total_tokens].each do |key|
        payload[key] = non_negative_integer_or_nil(hash_value(value, key))
      end
      payload.delete_if { |_key, item| item.nil? }
      payload
    end

    def compact_claims(value)
      return {} unless value.is_a?(Hash)

      payload = {
        "summary" => bounded_string_or_nil(hash_value(value, "summary")),
        "verdict" => bounded_string_or_nil(hash_value(value, "verdict"))
      }
      findings = hash_value(value, "findings")
      if findings.is_a?(Hash)
        counts = CLAIM_SEVERITIES.each_with_object({}) do |severity, result|
          count = non_negative_integer_or_nil(hash_value(findings, severity))
          result[severity] = count unless count.nil?
        end
        payload["findings"] = counts unless counts.empty?
      end
      payload.delete_if { |_key, item| item.nil? || item == "" }
      payload
    end

    def compact_validation(value)
      return nil unless value.is_a?(Hash)

      payload = {}
      payload["status"] = bounded_string_or_nil(value["status"])
      payload["commands"] = compact_commands(value["commands"])
      payload["final_reported"] = !!value["final_reported"] if value.key?("final_reported")
      payload.delete_if { |_key, item| item.nil? || item == [] }
      payload.empty? ? nil : payload
    end

    def compact_commands(value)
      Array(value).first(MAX_COMMANDS).filter_map do |entry|
        next unless entry.is_a?(Hash)

        compact = {
          "cmd" => bounded_string_or_nil(entry["cmd"]),
          "exit_code" => integer_or_nil(entry["exit_code"]),
          "status" => bounded_string_or_nil(entry["status"]),
          "duration_s" => finite_float_or_nil(entry["duration_s"])
        }
        compact.delete_if { |_key, item| item.nil? }
        compact.empty? ? nil : compact
      end
    end

    def compact_outcome(value)
      return nil unless value.is_a?(Hash)

      status = value["status"].to_s
      return nil unless OUTCOME_STATUSES.include?(status)

      payload = {
        "status" => status,
        "summary" => bounded_string_or_nil(value["summary"]),
        "commit_sha" => bounded_string_or_nil(value["commit_sha"])
      }
      payload.delete_if { |_key, item| item.nil? }
      payload
    end

    def compact_artifacts(value)
      Array(value).first(MAX_ARTIFACTS).filter_map do |entry|
        next unless entry.is_a?(Hash)

        compact = {
          "type" => bounded_string_or_nil(entry["type"]),
          "summary" => bounded_string_or_nil(entry["summary"]),
          "evidence" => string_array(entry["evidence"], max_items: MAX_EVIDENCE_ITEMS),
          "confidence" => finite_float_or_nil(entry["confidence"]),
          "canonical_ref" => bounded_string_or_nil(entry["canonical_ref"])
        }
        compact.delete_if { |_key, item| item.nil? || item == [] }
        compact.empty? ? nil : compact
      end
    end

    def validation_failure(path, status:, diagnostics:, bytes: nil, sha256: nil)
      ValidationResult.new(
        ok: false,
        status: status,
        path: path,
        bytes: bytes,
        sha256: sha256,
        schema: nil,
        diagnostics: diagnostics.first(MAX_DIAGNOSTICS),
        report: nil
      )
    end

    def diagnostic(code, path, message)
      {
        "code" => code,
        "path" => path,
        "message" => bounded_string(message)
      }
    end

    def string_array(value, max_items:)
      Array(value).first(max_items).filter_map do |item|
        text = bounded_string_or_nil(item)
        text unless text.nil? || text.empty?
      end
    end

    def bounded_string_or_nil(value)
      return nil if value.nil?

      bounded_string(value)
    end

    def bounded_string(value)
      text = value.to_s
      return text if text.length <= MAX_STRING_LENGTH

      text[0, MAX_STRING_LENGTH]
    end

    def integer_or_nil(value)
      return nil if value.nil?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def non_negative_integer_or_nil(value)
      integer = integer_or_nil(value)
      integer if integer && integer >= 0
    end

    def hash_value(hash, key)
      return nil unless hash.is_a?(Hash)
      return hash[key] if hash.key?(key)

      hash[key.to_sym]
    end

    def finite_float_or_nil(value)
      return nil if value.nil?

      number = Float(value)
      number.finite? ? number : nil
    rescue ArgumentError, TypeError
      nil
    end

    def finite_number?(value)
      value.is_a?(Numeric) && value.finite?
    end

    def finite_non_negative_number?(value)
      finite_number?(value) && value >= 0
    end

    def non_empty_string?(value)
      value.is_a?(String) && !value.empty? && value.length <= MAX_STRING_LENGTH
    end

    def boolean_or_nil(value)
      value if boolean?(value)
    end

    def boolean?(value)
      value == true || value == false
    end

    def file_sha256(path)
      digest = Digest::SHA256.new
      File.open(path, "rb") do |file|
        buffer = +""
        digest.update(buffer) while file.read(16 * 1024, buffer)
      end
      digest.hexdigest
    end

    def safe_file_size(path)
      File.size(path) if File.file?(path)
    rescue StandardError
      nil
    end

    def safe_file_sha256(path)
      file_sha256(path) if File.file?(path)
    rescue StandardError
      nil
    end
  end
end
