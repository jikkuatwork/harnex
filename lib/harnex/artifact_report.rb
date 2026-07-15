require "digest"
require "fileutils"
require "json"

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

    def validate_commands(value, diagnostics)
      unless value.is_a?(Array)
        diagnostics << diagnostic("array_required", "$.validation.commands", "validation.commands must be an array")
        return
      end
      if value.length > MAX_COMMANDS
        diagnostics << diagnostic(
          "too_many_items",
          "$.validation.commands",
          "validation.commands may contain at most #{MAX_COMMANDS} entries"
        )
      end

      value.first(MAX_COMMANDS).each_with_index do |entry, index|
        path = "$.validation.commands[#{index}]"
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

    def validate_final_contract(report, diagnostics)
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
          "artifact_count" => artifacts.length
        )
      }
      payload["validation"] = validation if validation
      payload["artifacts"] = artifacts unless artifacts.empty?
      payload["outcome"] = outcome if outcome
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
