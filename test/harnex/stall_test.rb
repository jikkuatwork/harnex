require_relative "../test_helper"

# #76: the shared "no progress" predicate over a live status payload.
class StallTest < Minitest::Test
  def structured(turn_active: true, turn_age_s: 900.0, model_idle_s: 600.0, tool_idle_s: 1200.0)
    {
      "work_state" => "running", "done" => false, "log_idle_s" => 5,
      "activity" => {
        "status" => "observed", "source" => "pi_rpc", "turn_active" => turn_active,
        "turn_age_s" => turn_age_s, "model_idle_s" => model_idle_s, "tool_idle_s" => tool_idle_s
      }
    }
  end

  def test_structured_progress_is_the_most_recent_turn_model_or_tool_event
    assert_equal({ "clock" => "activity", "idle_s" => 600.0 }, Harnex::Stall.progress_idle(structured))
    # Early in a turn the model/tool clocks are unset; the turn start counts.
    assert_equal 30.0, Harnex::Stall.progress_idle(structured(turn_age_s: 30.0, model_idle_s: nil, tool_idle_s: nil))["idle_s"]
  end

  def test_holm_q156_shape_stalls_while_model_is_nominally_active
    payload = structured(turn_age_s: 3400.0, model_idle_s: 1600.0, tool_idle_s: 3000.0)
    payload["activity"]["model_active"] = true

    assert_equal({ "clock" => "activity", "idle_s" => 1600.0, "threshold_s" => 1500.0 },
                 Harnex::Stall.stalled(payload, 1500.0))
    assert_nil Harnex::Stall.stalled(payload, 1800.0)
  end

  def test_structured_clocks_count_only_during_an_active_turn
    assert_nil Harnex::Stall.progress_idle(structured(turn_active: false))
  end

  def test_settled_work_never_stalls
    %w[done task_complete task_failed].each do |key|
      payload = structured.merge(key => true)
      assert_nil Harnex::Stall.progress_idle(payload), key
    end
  end

  def test_pty_sessions_fall_back_to_output_log_idle
    payload = { "work_state" => "running", "log_idle_s" => 700, "activity" => { "status" => "unknown" } }

    assert_equal({ "clock" => "output_log", "idle_s" => 700.0 }, Harnex::Stall.progress_idle(payload))
    assert_nil Harnex::Stall.progress_idle(payload.merge("log_idle_s" => nil))
    assert_nil Harnex::Stall.progress_idle(nil)
  end
end
