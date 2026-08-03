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

  def test_harness_observed_receipt_is_final_with_commands_usage_and_advisory_claims
    Dir.mktmpdir("harnex-observed-receipt") do |dir|
      path = File.join(dir, "receipt.json")
      result = Harnex::ArtifactReport.write_observed(
        path,
        id: "cx-r-64",
        session_id: "session-64",
        generated_at: Time.utc(2026, 8, 3, 5, 0, 0),
        successful: true,
        outcome_status: "accepted",
        outcome_summary: "Harnex observed successful work.",
        git: {
          status: "observed",
          start_sha: "a" * 40,
          end_sha: "b" * 40,
          branch: "main",
          changed_paths: ["lib/harnex/artifact_report.rb"],
          loc_added: 12,
          loc_removed: 3,
          files_changed: 1,
          commits: 1
        },
        commands: [
          { "cmd" => "ruby failing_test.rb", "exit_code" => 1, "status" => "failed" },
          { "cmd" => "ruby passing_test.rb", "exit_code" => 0, "status" => "completed" }
        ],
        turn: {
          status: "completed",
          outcome_class: "completed_with_proof",
          task_complete: true,
          task_failed: false,
          accepted: true,
          exit_code: 0
        },
        usage: { status: "observed", input_tokens: 100, output_tokens: 20, total_tokens: 120 },
        claims: {
          summary: "Review found one medium-priority issue.",
          verdict: "changes_requested",
          findings: { P1: 0, P2: 1, P3: 0 }
        },
        command_observation: "observed"
      )

      assert result.ok
      assert Harnex::ArtifactReport.accepted_final?(result)
      report = JSON.parse(File.read(path))
      assert_equal "harnex", report.dig("receipt", "author")
      assert_equal 1, report.dig("receipt", "version")
      assert_equal [1, 0], report.dig("observed", "commands").map { |command| command.fetch("exit_code") }
      assert_equal 120, report.dig("observed", "usage", "total_tokens")
      assert_equal "changes_requested", report.dig("claims", "verdict")
      assert_equal({ "P1" => 0, "P2" => 1, "P3" => 0 }, report.dig("claims", "findings"))
      # An intermediate failed command and a negative review verdict remain
      # evidence/claims; neither can counterfeit or invalidate receipt authorship.
      assert_equal "fail", report.dig("validation", "status")
      assert_equal "accepted", report.dig("outcome", "status")
    end
  end

  def test_harness_no_change_receipt_requires_observed_zero_delta
    Dir.mktmpdir("harnex-observed-no-change") do |dir|
      path = File.join(dir, "receipt.json")
      sha = "c" * 40
      Harnex::ArtifactReport.write_observed(
        path,
        id: "cx-r-64",
        session_id: "session-no-change",
        generated_at: Time.now.utc,
        successful: true,
        outcome_status: "no_change",
        outcome_summary: "Harnex observed successful completion with no Git delta.",
        git: {
          status: "observed", start_sha: sha, end_sha: sha, branch: "main",
          changed_paths: [], loc_added: 0, loc_removed: 0, files_changed: 0, commits: 0
        },
        commands: [],
        turn: { status: "completed", task_complete: true, task_failed: false, accepted: true },
        usage: { status: "unsupported" },
        claims: {},
        command_observation: "unsupported"
      )

      assert Harnex::ArtifactReport.validate(path, final: true).ok
      document = JSON.parse(File.read(path))
      document["observed"]["git"]["end_sha"] = "d" * 40
      File.write(path, JSON.generate(document))
      invalid = Harnex::ArtifactReport.validate(path, final: true)
      refute invalid.ok
      assert_includes invalid.diagnostics.map { |item| item.fetch("code") }, "no_change_unobserved"
    end
  end

  def test_generated_receipt_truncates_evidence_to_the_hard_byte_limit
    Dir.mktmpdir("harnex-observed-bounds") do |dir|
      path = File.join(dir, "receipt.json")
      commands = Harnex::ArtifactReport::MAX_COMMANDS.times.map do |index|
        { "cmd" => "#{index}:#{'x' * Harnex::ArtifactReport::MAX_STRING_LENGTH}", "exit_code" => 0 }
      end
      paths = Harnex::ArtifactReport::MAX_CHANGED_PATHS.times.map do |index|
        "#{index}/#{'p' * Harnex::ArtifactReport::MAX_STRING_LENGTH}"
      end
      result = Harnex::ArtifactReport.write_observed(
        path,
        id: "bounded",
        session_id: "bounded-session",
        generated_at: Time.now.utc,
        successful: true,
        outcome_status: "accepted",
        outcome_summary: "bounded receipt",
        git: {
          status: "observed", start_sha: "a" * 40, end_sha: "b" * 40,
          branch: "main", changed_paths: paths, loc_added: 1, loc_removed: 0,
          files_changed: paths.length, commits: 1
        },
        commands: commands,
        turn: { status: "completed", task_complete: true, task_failed: false, accepted: true },
        usage: { status: "missing" },
        claims: {},
        command_observation: "observed"
      )

      assert result.ok
      assert_operator File.size(path), :<=, Harnex::ArtifactReport::MAX_BYTES
      report = result.report
      assert_equal true, report.dig("observed", "commands_truncated")
      assert_equal true, report.dig("observed", "git", "changed_paths_truncated")
      assert_operator report.dig("observed", "commands").length, :<, commands.length
      assert_operator report.dig("observed", "git", "changed_paths").length, :<, paths.length
    end
  end

  def test_claim_extraction_is_bounded_and_legacy_outcome_is_only_a_claim
    Dir.mktmpdir("harnex-observed-claims") do |dir|
      claims_path = File.join(dir, "claims.json")
      File.write(claims_path, JSON.generate(
        claims: {
          summary: "review complete",
          verdict: "reject",
          findings: { P1: 2, P2: -1, P3: "not-a-count", P4: 99 },
          ignored: "not copied"
        }
      ))
      assert_equal(
        {
          "summary" => "review complete",
          "verdict" => "reject",
          "findings" => { "P1" => 2 }
        },
        Harnex::ArtifactReport.extract_claims(claims_path)
      )

      File.write(claims_path, JSON.generate(
        schema: Harnex::ArtifactReport::SCHEMA,
        outcome: { status: "rejected", summary: "legacy review verdict" }
      ))
      assert_equal(
        { "summary" => "legacy review verdict", "verdict" => "rejected" },
        Harnex::ArtifactReport.extract_claims(claims_path)
      )
    end
  end
end
