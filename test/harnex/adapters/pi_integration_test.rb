require_relative "../../test_helper"
require "timeout"

# Real Pi RPC integration. Skipped by default to keep the suite hermetic and
# free of provider cost; set PI_INTEGRATION=1 to opt in.
class PiIntegrationTest < Minitest::Test
  def setup
    skip("set PI_INTEGRATION=1 to run") unless ENV["PI_INTEGRATION"] == "1"
    skip("Pi CLI not on PATH") unless system("which pi > /dev/null 2>&1")
  end

  def test_current_rpc_lifecycle_and_delta_contract
    adapter = Harnex::Adapters::Pi.new([
      "--no-session",
      "--no-extensions",
      "--no-skills",
      "--no-prompt-templates",
      "--no-approve"
    ])
    notifications = []
    mutex = Mutex.new
    adapter.on_notification { |event| mutex.synchronize { notifications << event } }

    Timeout.timeout(90) do
      adapter.start_rpc(env: ENV.to_h, cwd: Dir.pwd)
      adapter.dispatch(prompt: "Reply with exactly HARNEX_PI_RPC_OK and no other text.")
      sleep 0.05 until mutex.synchronize { notifications.any? { |event| event["type"] == "agent_settled" } }
    end

    captured = mutex.synchronize { notifications.dup }
    event_types = captured.map { |event| event["type"] }
    assert_includes event_types, "agent_end"
    assert_includes event_types, "agent_settled"
    assert_operator event_types.index("agent_end"), :<, event_types.index("agent_settled")
    assert_equal :prompt, adapter.state

    updates = captured.select { |event| event["type"] == "message_update" }
    refute_empty updates
    assert updates.all? { |event| !event.key?("message") },
      "Pi >= 0.84 emits delta-only message_update events"

    final = captured.reverse.find do |event|
      event["type"] == "message_end" && event.dig("message", "role") == "assistant"
    end
    assert_equal "stop", final.dig("message", "stopReason")
  ensure
    adapter&.close
  end
end
