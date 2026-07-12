require_relative "../test_helper"

class ContextTelemetryTest < Minitest::Test
  def test_tracks_terminal_sample_and_independent_high_water_marks
    telemetry = Harnex::ContextTelemetry.new(
      status: "observed",
      source: "pi_get_session_stats"
    )

    telemetry.record(tokens: 100, window_tokens: 1_000, percent: 10)
    telemetry.record(tokens: 700, window_tokens: 2_000, percent: 35)
    telemetry.record(tokens: 500, window_tokens: 1_000, percent: 50)

    summary = telemetry.snapshot
    assert_equal "observed", summary.fetch(:status)
    assert_equal "pi_get_session_stats", summary.fetch(:source)
    assert_equal 500, summary.fetch(:terminal_tokens)
    assert_equal 1_000, summary.fetch(:window_tokens)
    assert_equal 50.0, summary.fetch(:terminal_percent)
    assert_equal 700, summary.fetch(:peak_tokens)
    assert_equal 50.0, summary.fetch(:peak_percent)
    assert_equal 3, summary.fetch(:samples)
    assert_equal 0, summary.fetch(:missing_samples)
    assert_equal "observed", summary.fetch(:latest_sample_status)
  end

  def test_missing_sample_preserves_final_valid_and_peak_values
    telemetry = Harnex::ContextTelemetry.new(
      status: "observed",
      source: "pi_get_session_stats"
    )

    telemetry.record(tokens: 118_000, window_tokens: 200_000, percent: 59)
    telemetry.record(tokens: nil, window_tokens: 200_000, percent: nil)

    summary = telemetry.snapshot
    assert_equal "observed", summary.fetch(:status)
    assert_equal 118_000, summary.fetch(:terminal_tokens)
    assert_equal 118_000, summary.fetch(:peak_tokens)
    assert_equal 59.0, summary.fetch(:terminal_percent)
    assert_equal 59.0, summary.fetch(:peak_percent)
    assert_equal 2, summary.fetch(:samples)
    assert_equal 1, summary.fetch(:missing_samples)
    assert_equal "missing", summary.fetch(:latest_sample_status)
  end

  def test_missing_only_sample_does_not_fabricate_zero
    telemetry = Harnex::ContextTelemetry.new(
      status: "estimated",
      source: "codex_thread_token_usage_last"
    )

    telemetry.record(tokens: nil, window_tokens: 200_000, percent: nil)

    summary = telemetry.snapshot
    assert_equal "missing", summary.fetch(:status)
    assert_nil summary.fetch(:terminal_tokens)
    assert_nil summary.fetch(:terminal_percent)
    assert_nil summary.fetch(:peak_tokens)
    assert_nil summary.fetch(:peak_percent)
    assert_equal 1, summary.fetch(:samples)
    assert_equal 1, summary.fetch(:missing_samples)
    assert_equal "missing", summary.fetch(:latest_sample_status)
  end

  def test_derives_full_window_percent_for_estimated_sources
    telemetry = Harnex::ContextTelemetry.new(
      status: "estimated",
      source: "codex_thread_token_usage_last"
    )

    telemetry.record(tokens: 64_000, window_tokens: 200_000)

    summary = telemetry.snapshot
    assert_equal "estimated", summary.fetch(:status)
    assert_equal 32.0, summary.fetch(:terminal_percent)
    assert_equal 32.0, summary.fetch(:peak_percent)
  end
end
