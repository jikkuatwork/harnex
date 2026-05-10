require_relative "../test_helper"
require "timeout"

# Plan 30 / issue #40 — Phase 1 empirical Q1 verification.
#
# Confirms that a fresh `codex app-server` subprocess can resume a
# `threadId` it did not create. The plan locks subprocess-restart as
# the cross-deployment-resume mechanism on the assumption that
# `thread/resume(threadId)` works against any fresh subprocess; if
# codex enforces client identity locally this test surfaces it before
# production code lands. See koder/plans/30_deployment_fallback.md.
#
# Skipped by default. Opt in with HARNEX_RUN_CODEX_INTEGRATION=1 and a
# `codex` binary on PATH.
class CodexResumeAcrossSubprocessTest < Minitest::Test
  TURN_TIMEOUT_S = 60

  def setup
    skip("set HARNEX_RUN_CODEX_INTEGRATION=1 to run") unless ENV["HARNEX_RUN_CODEX_INTEGRATION"] == "1"
    skip("codex CLI not on PATH") unless system("which codex > /dev/null 2>&1")
  end

  def test_thread_resume_across_a_fresh_subprocess
    adapter_a = Harnex::Adapters::CodexAppServer.new
    notes_a = []
    adapter_a.on_notification { |n| notes_a << n }

    Timeout.timeout(TURN_TIMEOUT_S) do
      adapter_a.start_rpc(env: ENV.to_h, cwd: Dir.pwd)
      adapter_a.dispatch(prompt: "Reply with the single word A and stop.")
      sleep 0.2 until notes_a.any? { |n| n["method"] == "turn/completed" }
    end

    thread_id = adapter_a.thread_id
    refute_nil thread_id, "subprocess A must produce a threadId"

    adapter_a.close
    adapter_a.terminate_subprocess
    adapter_a = nil

    adapter_b = Harnex::Adapters::CodexAppServer.new
    notes_b = []
    adapter_b.on_notification { |n| notes_b << n }

    Timeout.timeout(TURN_TIMEOUT_S) do
      adapter_b.start_rpc(env: ENV.to_h, cwd: Dir.pwd)
      adapter_b.resume(thread_id: thread_id)
      adapter_b.dispatch(prompt: "Reply with the single word B and stop.")
      sleep 0.2 until notes_b.any? { |n| n["method"] == "turn/completed" }
    end

    assert_includes notes_b.map { |n| n["method"] }, "turn/completed",
      "subprocess B must complete a resumed turn"
    assert_equal thread_id, adapter_b.thread_id,
      "resumed adapter must keep the same threadId"
  ensure
    adapter_a&.close
    adapter_a&.terminate_subprocess
    adapter_b&.close
    adapter_b&.terminate_subprocess
  end
end
