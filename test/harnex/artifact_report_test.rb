require_relative "../test_helper"
require "digest"

class ArtifactReportTest < Minitest::Test
  def test_ingests_valid_v1_report_compactly
    Dir.mktmpdir("harnex-artifact-report") do |dir|
      path = File.join(dir, "report.json")
      report = {
        schema: Harnex::ArtifactReport::SCHEMA,
        status: "pass",
        canonical_artifacts: ["koder/issues/52_typed_artifact_validation_sidecars.md"],
        outcome: {
          status: "accepted",
          summary: "Queue gate accepted the implementation.",
          commit_sha: "0123456789abcdef"
        },
        validation: {
          status: "pass",
          final_reported: true,
          commands: [
            { cmd: "ruby -Ilib -Itest test/harnex/artifact_report_test.rb", exit_code: 0 }
          ]
        },
        artifacts: [
          {
            type: "gate",
            summary: "Artifact report ingestion passed.",
            evidence: ["test/harnex/artifact_report_test.rb"],
            confidence: 1.0,
            canonical_ref: "koder/issues/52_typed_artifact_validation_sidecars.md"
          }
        ]
      }
      File.write(path, JSON.generate(report))

      payload = Harnex::ArtifactReport.ingest(path)

      metadata = payload.fetch("artifact_report")
      assert_equal "ok", metadata.fetch("ingest_status")
      assert_equal Harnex::ArtifactReport::SCHEMA, metadata.fetch("schema")
      assert_equal "pass", metadata.fetch("report_status")
      assert_equal path, metadata.fetch("path")
      assert_equal File.size(path), metadata.fetch("bytes")
      assert_equal Digest::SHA256.file(path).hexdigest, metadata.fetch("sha256")
      assert_equal ["koder/issues/52_typed_artifact_validation_sidecars.md"], metadata.fetch("canonical_artifacts")
      assert_equal 1, metadata.fetch("artifact_count")

      outcome = payload.fetch("outcome")
      assert_equal "accepted", outcome.fetch("status")
      assert_equal "Queue gate accepted the implementation.", outcome.fetch("summary")
      assert_equal "0123456789abcdef", outcome.fetch("commit_sha")

      validation = payload.fetch("validation")
      assert_equal "pass", validation.fetch("status")
      assert_equal true, validation.fetch("final_reported")
      assert_equal "ruby -Ilib -Itest test/harnex/artifact_report_test.rb", validation.fetch("commands").first.fetch("cmd")
      assert_equal 0, validation.fetch("commands").first.fetch("exit_code")

      artifact = payload.fetch("artifacts").first
      assert_equal "gate", artifact.fetch("type")
      assert_equal "Artifact report ingestion passed.", artifact.fetch("summary")
      assert_equal ["test/harnex/artifact_report_test.rb"], artifact.fetch("evidence")
      assert_equal 1.0, artifact.fetch("confidence")
      assert_equal "koder/issues/52_typed_artifact_validation_sidecars.md", artifact.fetch("canonical_ref")
    end
  end

  def test_invalid_outcome_status_is_fail_soft_with_field_diagnostic
    Dir.mktmpdir("harnex-artifact-report") do |dir|
      path = File.join(dir, "report.json")
      File.write(path, JSON.generate(
        schema: Harnex::ArtifactReport::SCHEMA,
        outcome: { status: "made_up" }
      ))

      payload = Harnex::ArtifactReport.ingest(path)
      refute payload.key?("outcome")
      assert_equal "invalid", payload.dig("artifact_report", "ingest_status")
      diagnostic = payload.dig("artifact_report", "diagnostics", 0)
      assert_equal "$.outcome.status", diagnostic.fetch("path")
      refute_includes diagnostic.fetch("message"), "made_up"
    end
  end

  def test_missing_report_is_warning_payload
    Dir.mktmpdir("harnex-artifact-report") do |dir|
      path = File.join(dir, "missing.json")
      payload = Harnex::ArtifactReport.ingest(path)
      metadata = payload.fetch("artifact_report")

      assert_equal "missing", metadata.fetch("ingest_status")
      assert_equal path, metadata.fetch("path")
      assert_nil metadata.fetch("bytes")
      assert_nil metadata.fetch("sha256")
      assert_match(/not found/, metadata.fetch("warning"))
      refute payload.key?("validation")
      refute payload.key?("artifacts")
    end
  end

  def test_malformed_report_is_warning_payload_with_hash
    Dir.mktmpdir("harnex-artifact-report") do |dir|
      path = File.join(dir, "malformed.json")
      File.write(path, "{")

      metadata = Harnex::ArtifactReport.ingest(path).fetch("artifact_report")

      assert_equal "malformed", metadata.fetch("ingest_status")
      assert_equal 1, metadata.fetch("bytes")
      assert_equal Digest::SHA256.file(path).hexdigest, metadata.fetch("sha256")
      assert_match(/malformed artifact report JSON/, metadata.fetch("warning"))
    end
  end

  def test_unsupported_schema_is_warning_payload
    Dir.mktmpdir("harnex-artifact-report") do |dir|
      path = File.join(dir, "unsupported.json")
      File.write(path, JSON.generate(schema: "example.v0"))

      metadata = Harnex::ArtifactReport.ingest(path).fetch("artifact_report")

      assert_equal "unsupported_schema", metadata.fetch("ingest_status")
      assert_equal "example.v0", metadata.fetch("schema")
      assert_match(/unsupported artifact report schema/, metadata.fetch("warning"))
    end
  end

  def test_oversized_report_is_warning_payload_without_parsing
    Dir.mktmpdir("harnex-artifact-report") do |dir|
      path = File.join(dir, "oversized.json")
      File.binwrite(path, "x" * (Harnex::ArtifactReport::MAX_BYTES + 1))

      metadata = Harnex::ArtifactReport.ingest(path).fetch("artifact_report")

      assert_equal "oversized", metadata.fetch("ingest_status")
      assert_equal Harnex::ArtifactReport::MAX_BYTES + 1, metadata.fetch("bytes")
      assert_equal Digest::SHA256.file(path).hexdigest, metadata.fetch("sha256")
      assert_match(/max is/, metadata.fetch("warning"))
    end
  end

  def test_validator_rejects_string_outcome_and_missing_command_exit_code
    Dir.mktmpdir("harnex-artifact-report") do |dir|
      path = File.join(dir, "invalid.json")
      File.write(path, JSON.generate(
        schema: Harnex::ArtifactReport::SCHEMA,
        outcome: "accepted",
        validation: {
          status: "pass",
          commands: [{ cmd: "ruby -c lib/harnex/artifact_report.rb" }]
        }
      ))

      result = Harnex::ArtifactReport.validate(path)

      refute result.ok
      assert_equal "invalid", result.status
      assert_equal ["$.outcome", "$.validation.commands[0].exit_code"],
        result.diagnostics.map { |item| item.fetch("path") }
    end
  end

  def test_validator_rejects_missing_schema_without_echoing_other_fields
    Dir.mktmpdir("harnex-artifact-report") do |dir|
      path = File.join(dir, "missing-schema.json")
      secret = "private-report-value"
      File.write(path, JSON.generate(
        status: "pass",
        outcome: { status: "accepted", summary: secret }
      ))

      result = Harnex::ArtifactReport.validate(path)

      refute result.ok
      assert_equal "unsupported_schema", result.status
      assert_equal "$.schema", result.diagnostics.first.fetch("path")
      refute_includes JSON.generate(result.public_payload), secret
    end
  end

  def test_final_validator_accepts_explicit_no_change_proof
    Dir.mktmpdir("harnex-artifact-report") do |dir|
      path = File.join(dir, "no-change.json")
      File.write(path, JSON.generate(
        schema: Harnex::ArtifactReport::SCHEMA,
        status: "pass",
        outcome: { status: "no_change", summary: "Repository already satisfies the requested invariant." },
        validation: { status: "not_run", commands: [], final_reported: true },
        artifacts: []
      ))

      result = Harnex::ArtifactReport.validate(path, final: true)

      assert result.ok
      assert_equal "valid", result.status
      assert Harnex::ArtifactReport.accepted_final?(result)
    end
  end

  def test_initialized_skeleton_is_schema_valid_but_not_final
    Dir.mktmpdir("harnex-artifact-report") do |dir|
      path = File.join(dir, "nested", "report.json")
      assert_equal path, Harnex::ArtifactReport.initialize_file(path)

      assert Harnex::ArtifactReport.validate(path).ok
      final = Harnex::ArtifactReport.validate(path, final: true)
      refute final.ok
      assert_includes final.diagnostics.map { |item| item.fetch("path") }, "$.validation.final_reported"
    end
  end
end
