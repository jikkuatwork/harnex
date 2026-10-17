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

  # Issue #70: commands that ran without structured exit evidence keep a clean
  # observed history from reading as a pass, and are counted explicitly.
  def test_partial_command_observation_reports_unobserved_count_and_unknown_validation
    Dir.mktmpdir("harnex-observed-partial") do |dir|
      path = File.join(dir, "receipt.json")
      attributes = {
        id: "pi-i-70",
        session_id: "session-partial",
        generated_at: Time.now.utc,
        successful: true,
        outcome_status: "accepted",
        outcome_summary: "Harnex observed accepted completion.",
        git: { status: "unavailable" },
        commands: [{ "cmd" => "ruby -c lib/a.rb", "exit_code" => 0, "status" => "completed" }],
        turn: { status: "completed", task_complete: true, task_failed: false, accepted: true },
        usage: { status: "missing" },
        claims: {},
        command_observation: "partial",
        commands_unobserved: 1
      }

      result = Harnex::ArtifactReport.write_observed(path, **attributes)

      assert result.ok
      assert Harnex::ArtifactReport.accepted_final?(result)
      report = JSON.parse(File.read(path))
      assert_equal "partial", report.dig("observed", "command_observation")
      assert_equal 1, report.dig("observed", "commands_unobserved")
      assert_equal "unknown", report.dig("validation", "status")

      failed = attributes.merge(commands: attributes[:commands] + [{ "cmd" => "false", "exit_code" => 1 }])
      assert_equal "fail", Harnex::ArtifactReport.write_observed(path, **failed).report.dig("validation", "status")

      clean = attributes.merge(command_observation: "observed", commands_unobserved: 0)
      report = Harnex::ArtifactReport.write_observed(path, **clean).report
      assert_equal "pass", report.dig("validation", "status")
      refute report["observed"].key?("commands_unobserved")
    end
  end

  # --- #68: final gates separate from command history ---

  def gate_receipt_attributes(commands:, final_gates:, command_observation: "observed", commands_had_failures: nil)
    {
      id: "pi-i-68", session_id: "session-gates", generated_at: Time.now.utc,
      successful: true, outcome_status: "accepted", outcome_summary: "Harnex observed accepted completion.",
      git: { status: "unavailable" }, commands: commands,
      turn: { status: "completed", task_complete: true, task_failed: false, accepted: true },
      usage: { status: "missing" }, claims: {}, command_observation: command_observation,
      final_gates: final_gates, commands_had_failures: commands_had_failures
    }
  end

  def test_declared_final_gates_decide_validation_while_history_flag_keeps_exploratory_failures
    Dir.mktmpdir("harnex-final-gates") do |dir|
      path = File.join(dir, "receipt.json")
      commands = [
        { "cmd" => "rg -n nothing nowhere/", "exit_code" => 2 },
        { "cmd" => "rake test", "exit_code" => 0 }
      ]
      result = Harnex::ArtifactReport.write_observed(
        path, **gate_receipt_attributes(commands: commands, final_gates: [{ "cmd" => "rake test", "exit_code" => 0 }])
      )

      assert result.ok, result.diagnostics.inspect
      validation = JSON.parse(File.read(path)).fetch("validation")
      assert_equal "pass", validation["status"]
      assert_equal true, validation["commands_had_failures"]
      assert_equal "pass", validation.dig("final_gates", "status")
      assert_equal [{ "cmd" => "rake test", "exit_code" => 0 }], validation.dig("final_gates", "gates")

      ingested = Harnex::ArtifactReport.ingest(path).fetch("validation")
      assert_equal true, ingested["commands_had_failures"]
      assert_equal(
        { "status" => "pass", "declared" => 1, "observed_pass" => 1, "observed_fail" => 0, "missing" => 0 },
        ingested["final_gates"]
      )
    end
  end

  def test_failed_or_missing_final_gate_fails_and_partial_observation_reads_unknown
    failed = Harnex::ArtifactReport.build_observed(**gate_receipt_attributes(
      commands: [{ "cmd" => "rake test", "exit_code" => 1 }],
      final_gates: [{ "cmd" => "rake test", "exit_code" => 1 }, { "cmd" => "rake lint", "exit_code" => 0 }]
    ))
    assert_equal "fail", failed.dig("validation", "status")
    assert_equal 1, failed.dig("validation", "final_gates", "observed_fail")

    missing = gate_receipt_attributes(commands: [], final_gates: [{ "cmd" => "rake test", "exit_code" => nil }])
    assert_equal "fail", Harnex::ArtifactReport.build_observed(**missing).dig("validation", "status")
    %w[partial unsupported].each do |observation|
      document = Harnex::ArtifactReport.build_observed(**missing, command_observation: observation)
      assert_equal "unknown", document.dig("validation", "status"), observation
      assert_equal 1, document.dig("validation", "final_gates", "missing")
    end
  end

  def test_undeclared_final_gates_keep_legacy_validation
    document = Harnex::ArtifactReport.build_observed(**gate_receipt_attributes(
      commands: [{ "cmd" => "false", "exit_code" => 1 }, { "cmd" => "true", "exit_code" => 0 }],
      final_gates: nil
    ))
    assert_equal "fail", document.dig("validation", "status")
    assert_equal true, document.dig("validation", "commands_had_failures")
    assert_equal({ "declared" => 0, "observed_pass" => 0, "status" => "undeclared" }, document.dig("validation", "final_gates"))

    # The session's whole-history flag wins over the capped command window.
    windowed = Harnex::ArtifactReport.build_observed(**gate_receipt_attributes(
      commands: [{ "cmd" => "true", "exit_code" => 0 }], final_gates: nil, commands_had_failures: true
    ))
    assert_equal "fail", windowed.dig("validation", "status")
  end

  def test_final_gate_matching_is_exact_after_unwrapping_a_shell_transport
    assert Harnex::ArtifactReport.final_gate_matches?("rake test", "rake test")
    assert Harnex::ArtifactReport.final_gate_matches?("rake test", "/bin/bash -lc 'rake test'")
    assert Harnex::ArtifactReport.final_gate_matches?("rake test", "sh -c 'rake test'")
    refute Harnex::ArtifactReport.final_gate_matches?("rake test", "rake test ")
    refute Harnex::ArtifactReport.final_gate_matches?("rake test", "bash -lc 'rake test && true'")
    refute Harnex::ArtifactReport.final_gate_matches?("rake test", "python -c 'rake test'")
    refute Harnex::ArtifactReport.final_gate_matches?("rake test", "bash -lc 'unterminated")
    assert_equal ["a", "b"], Harnex::ArtifactReport.normalize_final_gates([" a ", "", "b", "a", 7])
  end

  def test_final_gates_are_validated_when_present
    document = Harnex::ArtifactReport.build_observed(**gate_receipt_attributes(
      commands: [], final_gates: [{ "cmd" => "rake test", "exit_code" => 0 }]
    ))
    assert_empty Harnex::ArtifactReport.validate_document(document)

    document["validation"]["final_gates"]["status"] = "maybe"
    document["validation"]["final_gates"]["declared"] = -1
    document["validation"]["final_gates"]["gates"] = [{ "cmd" => "", "exit_code" => "0" }]
    document["validation"]["commands_had_failures"] = "no"
    paths = Harnex::ArtifactReport.validate_document(document).map { |item| item.fetch("path") }
    assert_includes paths, "$.validation.final_gates.status"
    assert_includes paths, "$.validation.final_gates.declared"
    assert_includes paths, "$.validation.final_gates.gates[0].cmd"
    assert_includes paths, "$.validation.final_gates.gates[0].exit_code"
    assert_includes paths, "$.validation.commands_had_failures"
  end

  def test_observed_validation_rejects_unknown_command_observation_and_bad_unobserved_count
    Dir.mktmpdir("harnex-observed-enum") do |dir|
      path = File.join(dir, "receipt.json")
      Harnex::ArtifactReport.write_observed(
        path,
        id: "pi-i-70",
        session_id: "session-enum",
        generated_at: Time.now.utc,
        successful: false,
        outcome_status: "rejected",
        outcome_summary: "rejected",
        git: { status: "unavailable" },
        commands: [],
        turn: { status: "failed", task_complete: false, task_failed: true, accepted: false },
        usage: { status: "missing" },
        claims: {},
        command_observation: "unsupported"
      )
      document = JSON.parse(File.read(path))
      document["observed"]["command_observation"] = "guessed"
      document["observed"]["commands_unobserved"] = -1
      File.write(path, JSON.generate(document))

      codes = Harnex::ArtifactReport.validate(path).diagnostics.map { |item| item.fetch("path") }
      assert_includes codes, "$.observed.command_observation"
      assert_includes codes, "$.observed.commands_unobserved"
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
