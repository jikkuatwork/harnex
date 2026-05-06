require_relative "../../test_helper"
require "json"
require "timeout"

# Real codex app-server integration. Skipped by default to keep the
# suite hermetic; set CODEX_INTEGRATION=1 to opt in.
class CodexAppServerIntegrationTest < Minitest::Test
  def setup
    skip("set CODEX_INTEGRATION=1 to run") unless ENV["CODEX_INTEGRATION"] == "1"
    skip("codex CLI not on PATH") unless system("which codex > /dev/null 2>&1")
  end

  def test_full_dispatch_against_real_app_server
    adapter = Harnex::Adapters::CodexAppServer.new
    notifications = []
    adapter.on_notification { |n| notifications << n }

    Timeout.timeout(45) do
      adapter.start_rpc(env: ENV.to_h, cwd: Dir.pwd)
      adapter.dispatch(prompt: "Write a one-line poem about clouds. Then stop.")

      until notifications.any? { |n| n["method"] == "turn/completed" }
        sleep 0.2
      end
    end

    methods = notifications.map { |n| n["method"] }
    assert_includes methods, "turn/completed"
    assert_equal :prompt, adapter.state
  ensure
    adapter&.close
  end
end
