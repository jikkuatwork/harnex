require "digest"
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

    module_function

    def ingest(path)
      report_path = File.expand_path(path.to_s)
      return missing(report_path) unless File.file?(report_path)

      bytes = File.size(report_path)
      sha256 = file_sha256(report_path)
      if bytes > MAX_BYTES
        return warning(
          report_path,
          bytes: bytes,
          sha256: sha256,
          ingest_status: "oversized",
          warning: "artifact report is #{bytes} bytes; max is #{MAX_BYTES} bytes"
        )
      end

      parsed = JSON.parse(File.read(report_path, mode: "rb"))
      unless parsed.is_a?(Hash)
        return warning(
          report_path,
          bytes: bytes,
          sha256: sha256,
          ingest_status: "malformed",
          warning: "artifact report must be a JSON object"
        )
      end

      schema = parsed["schema"].to_s
      unless schema == SCHEMA
        return warning(
          report_path,
          bytes: bytes,
          sha256: sha256,
          ingest_status: "unsupported_schema",
          schema: schema.empty? ? nil : bounded_string(schema),
          warning: "unsupported artifact report schema #{schema.inspect}; expected #{SCHEMA}"
        )
      end

      build_payload(report_path, bytes: bytes, sha256: sha256, report: parsed)
    rescue JSON::ParserError => e
      warning(
        report_path,
        bytes: safe_file_size(report_path),
        sha256: safe_file_sha256(report_path),
        ingest_status: "malformed",
        warning: "malformed artifact report JSON: #{bounded_string(e.message)}"
      )
    rescue StandardError => e
      warning(
        report_path,
        bytes: safe_file_size(report_path),
        sha256: safe_file_sha256(report_path),
        ingest_status: "error",
        warning: "artifact report ingest failed: #{bounded_string(e.message)}"
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
        warning: "artifact report not found"
      )
    end

    def warning(path, bytes:, sha256:, ingest_status:, warning:, schema: nil)
      report = metadata(path, bytes: bytes, sha256: sha256, ingest_status: ingest_status, schema: schema)
      report["warning"] = bounded_string(warning)
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
      payload.delete_if { |_key, v| v.nil? || v == [] }
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
        compact.delete_if { |_key, v| v.nil? }
        compact.empty? ? nil : compact
      end
    end

    def compact_outcome(value)
      return nil unless value.is_a?(Hash)

      status = value["status"].to_s
      return nil unless %w[accepted rejected no_change unknown].include?(status)

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
        compact.delete_if { |_key, v| v.nil? || v == [] }
        compact.empty? ? nil : compact
      end
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
