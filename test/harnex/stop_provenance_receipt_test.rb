require_relative "../test_helper"

class StopProvenanceReceiptTest < Minitest::Test
  def attributes
    {
      id: "budget-test", session_id: "attempt-1", generated_at: Time.utc(2026, 9, 28),
      successful: false, outcome_status: "rejected", outcome_summary: "Runtime budget stopped active work.",
      git: { status: "unavailable" }, commands: [],
      turn: { status: "failed", task_complete: false, task_failed: true, accepted: false, exit_code: 124 },
      usage: { status: "unsupported" }, claims: {}, command_observation: "unsupported"
    }
  end

  def test_stop_provenance_survives_observed_receipt_and_ingestion
    Dir.mktmpdir("stop-receipt") do |dir|
      stop = Harnex::StopRequest.new(
        reason: "runtime_budget", origin: "runtime", work_state: "running",
        requested_at: Time.utc(2026, 9, 28), runtime_limit_s: 30
      ).to_h
      path = File.join(dir, "receipt.json")
      result = Harnex::ArtifactReport.write_observed(path, **attributes, stop: stop)
      assert result.ok, result.diagnostics.inspect
      ingested = Harnex::ArtifactReport.ingest(path)
      assert_equal "runtime_budget", ingested.dig("observed", "stop", "reason")
      assert_equal "runtime", ingested.dig("observed", "stop", "origin")
      assert_equal 30.0, ingested.dig("observed", "stop", "runtime_limit_s")
      assert_equal "rejected", ingested.dig("outcome", "status")
    end
  end

  def test_optional_stop_metadata_is_validated_and_unknown_payload_is_not_retained
    stop = {
      reason: "manual", origin: "cli", work_state: "completed",
      requested_at: "2026-09-28T00:00:00Z", secret: "unwanted-payload"
    }
    document = Harnex::ArtifactReport.build_observed(**attributes, stop: stop)
    assert_empty Harnex::ArtifactReport.validate_document(document)
    refute_includes JSON.generate(document), "unwanted-payload"
    document["observed"]["stop"]["reason"] = "unbounded-text"
    refute_empty Harnex::ArtifactReport.validate_document(document)
  end
end
