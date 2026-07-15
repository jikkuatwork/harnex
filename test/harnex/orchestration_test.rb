require_relative "../test_helper"
require "json"

class OrchestrationTest < Minitest::Test
  def test_sample_command_appends_bounded_external_primary_sample
    Dir.mktmpdir("harnex-orchestration-sample") do |dir|
      path = File.join(dir, "samples.jsonl")
      cli = Harnex::CLI.new([
        "orchestration", "sample",
        "--out", path,
        "--run-id", "orch-1",
        "--generation-id", "gen-1",
        "--project-id", "harnex",
        "--queue-id", "queue-055",
        "--session-id", "pi-primary-1",
        "--ts", "2026-07-15T12:00:00+05:30",
        "--context-tokens", "64000",
        "--context-window-tokens", "200000",
        "--context-percent", "32.0",
        "--usage-status", "observed",
        "--usage-input-tokens", "120000",
        "--usage-output-tokens", "9000",
        "--usage-total-tokens", "129000",
        "--tool-calls", "31",
        "--compactions", "1"
      ])

      out, = capture_io { assert_equal 0, cli.run }
      payload = JSON.parse(out)
      sample = JSON.parse(File.read(path).lines.last)

      assert_equal true, payload.fetch("ok")
      assert_equal "harnex.orchestrator_sample.v1", sample.fetch("schema")
      assert_equal "orch-1", sample.fetch("orchestration_run_id")
      assert_equal "gen-1", sample.fetch("generation_id")
      assert_equal "pi-primary-1", sample.fetch("session_id")
      assert_equal 64_000.0, sample.dig("context", "terminal_tokens")
      assert_equal 129_000.0, sample.dig("usage", "total_tokens")
      assert_equal 31, sample.fetch("tool_calls")
      assert_equal 1, sample.fetch("compactions")
    end
  end

  def test_report_counts_generations_workers_and_dedupes_accepted_outcomes
    dispatch_rows = [
      worker_row("impl-1a", entry: "A", outcome: "unknown", exit_reason: "failure", tokens: 10_000, duration_s: 50),
      worker_row("impl-1b", entry: "A", outcome: "accepted", exit_reason: "success", tokens: 20_000, duration_s: 70, attempt_kind: "fix"),
      worker_row("impl-2", entry: "B", outcome: "rejected", exit_reason: "success", tokens: 30_000, duration_s: 80),
      worker_row("impl-3", entry: "C", outcome: "unknown", exit_reason: "failure", tokens: nil, duration_s: 40)
    ]
    sample_rows = [
      sample("gen-1", "pi-1", ts: "2026-07-15T12:00:00+05:30", total_tokens: 100_000, context_tokens: 64_000, tool_calls: 10),
      sample("gen-2", "pi-2", ts: "2026-07-15T12:10:00+05:30", total_tokens: 80_000, context_tokens: 40_000, tool_calls: 7, rotation_reason: "clean_rotation")
    ]

    report = Harnex::Orchestration.build_report(
      dispatch_rows: dispatch_rows,
      sample_rows: sample_rows,
      run_id: "orch-1"
    )

    assert_equal "harnex.orchestration_tax.v1", report.fetch("schema")
    assert_equal 2, report.dig("primary", "generation_count")
    assert_equal 180_000.0, report.dig("primary", "usage", "total_tokens")
    assert_equal 64_000.0, report.dig("primary", "context", "peak_tokens")
    assert_equal 17, report.dig("primary", "tool_calls")
    assert_equal 4, report.dig("workers", "dispatches")
    assert_equal 1, report.dig("workers", "outcomes", "accepted")
    assert_equal 1, report.dig("workers", "outcomes", "rejected")
    assert_equal 1, report.dig("workers", "outcomes", "blocked")
    assert_equal ["entry_id:A"], report.dig("workers", "accepted_work_ids")
    assert_equal 60_000.0, report.dig("workers", "usage", "total_tokens")
    assert_equal 180_000.0, report.dig("ratios", "primary_total_tokens_per_accepted_entry")
  end

  def test_report_uses_harnex_managed_primary_dispatch_without_external_sample
    report = Harnex::Orchestration.build_report(
      dispatch_rows: [
        primary_row("primary-1", generation: "gen-1", tokens: 55_000, context_tokens: 42_000),
        worker_row("impl-1", entry: "A", outcome: "accepted", exit_reason: "success", tokens: 10_000)
      ],
      sample_rows: [],
      run_id: "orch-1"
    )

    assert_equal 1, report.dig("primary", "generation_count")
    assert_equal 55_000, report.dig("primary", "usage", "total_tokens")
    assert_equal 42_000, report.dig("primary", "context", "peak_tokens")
    assert_equal 0, report.dig("primary", "coverage", "external_samples")
    assert_equal 1, report.dig("workers", "outcomes", "accepted")
  end

  def test_report_marks_absent_primary_telemetry_as_missing
    report = Harnex::Orchestration.build_report(
      dispatch_rows: [worker_row("impl-1", entry: "A", outcome: "accepted", exit_reason: "success", tokens: 10_000)],
      sample_rows: [],
      run_id: "orch-1"
    )

    assert_equal 0, report.dig("primary", "generation_count")
    assert_equal "missing", report.dig("primary", "usage", "status")
    assert_equal "missing", report.dig("primary", "context", "status")
    assert_equal "observed", report.dig("workers", "usage", "status")
  end

  private

  def worker_row(id, entry:, outcome:, exit_reason:, tokens:, duration_s: 1, attempt_kind: "initial")
    {
      "meta" => { "id" => id },
      "queue" => {
        "project_id" => "harnex",
        "queue_id" => "queue-055",
        "entry_id" => entry,
        "phase" => "implement",
        "intent" => "queue-work"
      },
      "orchestration" => {
        "run_id" => "orch-1",
        "generation_id" => "gen-worker",
        "role" => "worker"
      },
      "usage" => {
        "status" => tokens ? "observed" : "unsupported",
        "total_tokens" => tokens
      },
      "attribution" => {
        "work_type" => "entry_id",
        "work_id" => entry
      },
      "outcome" => {
        "status" => outcome
      },
      "attempt" => {
        "run_id" => id,
        "kind" => attempt_kind,
        "status" => exit_reason == "success" ? "succeeded" : "failed"
      },
      "actual" => {
        "duration_s" => duration_s,
        "exit" => exit_reason
      }
    }
  end

  def primary_row(id, generation:, tokens:, context_tokens:)
    {
      "meta" => { "id" => id },
      "orchestration" => {
        "run_id" => "orch-1",
        "generation_id" => generation,
        "role" => "primary",
        "session_id" => id
      },
      "usage" => {
        "status" => "observed",
        "total_tokens" => tokens
      },
      "context" => {
        "status" => "observed",
        "terminal_tokens" => context_tokens,
        "peak_tokens" => context_tokens,
        "samples" => 1,
        "missing_samples" => 0
      },
      "actual" => {
        "duration_s" => 120,
        "tool_calls" => 5
      },
      "reliability" => {
        "compactions" => 0
      }
    }
  end

  def sample(generation_id, session_id, ts:, total_tokens:, context_tokens:, tool_calls:, rotation_reason: nil)
    Harnex::Orchestration.normalize_sample(
      "orchestration_run_id" => "orch-1",
      "generation_id" => generation_id,
      "project_id" => "harnex",
      "queue_id" => "queue-055",
      "session_id" => session_id,
      "ts" => ts,
      "usage" => {
        "status" => "observed",
        "total_tokens" => total_tokens
      },
      "context" => {
        "status" => "observed",
        "terminal_tokens" => context_tokens,
        "peak_tokens" => context_tokens
      },
      "tool_calls" => tool_calls,
      "rotation_reason" => rotation_reason
    )
  end
end
