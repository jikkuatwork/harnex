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

  def test_ignores_invalid_outcome_status_without_rejecting_v1_report
    Dir.mktmpdir("harnex-artifact-report") do |dir|
      path = File.join(dir, "report.json")
      File.write(path, JSON.generate(
        schema: Harnex::ArtifactReport::SCHEMA,
        outcome: { status: "made_up" }
      ))

      payload = Harnex::ArtifactReport.ingest(path)
      refute payload.key?("outcome")
      assert_equal "ok", payload.dig("artifact_report", "ingest_status")
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
end
