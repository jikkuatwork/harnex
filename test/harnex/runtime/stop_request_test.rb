require_relative "../../test_helper"

class StopRequestTest < Minitest::Test
  def test_bounded_immutable_provenance
    request = Harnex::StopRequest.new(
      reason: "manual", origin: "cli", work_state: "completed",
      requested_at: Time.utc(2026, 9, 28)
    )
    first = request.to_h
    assert_equal "manual", first[:reason]
    assert_equal "cli", first[:origin]
    assert_equal "completed", first[:work_state]
    assert_equal "2026-09-28T00:00:00.000Z", first[:requested_at]
    first[:reason] = "changed"
    assert_equal "manual", request.to_h[:reason]
    assert_raises(FrozenError) { request.to_h[:origin].replace("changed") }
  end

  def test_invalid_context_is_rejected_without_echoing_free_text
    error = assert_raises(ArgumentError) do
      Harnex::StopRequest.validate!(reason: "private-payload", origin: "cli")
    end
    refute_includes error.message, "private-payload"
    assert_raises(ArgumentError) { Harnex::StopRequest.validate!(reason: "manual", origin: "x" * 10_000) }
  end

  def test_runtime_limit_is_retained_as_a_number_not_free_text
    request = Harnex::StopRequest.new(
      reason: "runtime_budget", origin: "runtime", work_state: "running",
      runtime_limit_s: 30, requested_at: Time.utc(2026, 9, 28)
    )
    assert_equal 30.0, request.to_h[:runtime_limit_s]
  end
end
