require_relative "../../test_helper"

# #57: the dispatch row's outcome.class refines unknown/failed terminals from
# process signals Harnex already holds, and leaves completion verdicts alone.
class SessionOutcomeClassTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("harnex-outcome-class")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def session(adapter: Harnex::Adapters::Generic.new("sh", []))
    Harnex::Session.new(adapter: adapter, command: ["sh"], repo_root: @tmp, host: "127.0.0.1", id: "outcome")
  end

  def refine(base, **ivars)
    target = session
    ivars.each { |name, value| target.instance_variable_set(:"@#{name}", value) }
    target.send(:refine_terminal_outcome_class, base)
  end

  def stop(reason, work_state)
    origin = reason == "runtime_budget" ? "runtime" : "cli"
    Harnex::StopRequest.new(reason: reason, origin: origin, work_state: work_state)
  end

  def test_completion_and_proof_classes_are_never_refined
    (Harnex::Session::OUTCOME_CLASSES - %w[unknown task_failed]).each do |klass|
      assert_equal klass, refine(klass, exit_reason: "boot_failure", exit_code: 124,
                                         stop_request: stop("manual", "running"))
    end
  end

  def test_runtime_budget_stop_of_running_work_is_timeout
    assert_equal "timeout", refine("unknown", stop_request: stop("runtime_budget", "running"), exit_code: 124)
    assert_equal "timeout", refine("task_failed", stop_request: stop("runtime_budget", "running"))
    assert_equal "timeout", refine("unknown", exit_code: 124)
  end

  def test_caller_stop_of_running_work_is_stopped_by_caller
    assert_equal "stopped_by_caller", refine("unknown", stop_request: stop("manual", "running"))
    assert_equal "stopped_by_caller", refine("task_failed", stop_request: stop("manual", "running"))
  end

  def test_failure_that_preceded_the_stop_stays_task_failed
    assert_equal "task_failed", refine("task_failed", stop_request: stop("manual", "failed"))
    assert_equal "task_failed", refine("task_failed", exit_code: 124, exit_reason: "timeout")
    assert_equal "task_failed", refine("task_failed", exit_reason: "boot_failure")
  end

  def test_process_exit_paths_classify_distinctly
    assert_equal "boot_failure", refine("unknown", exit_reason: "boot_failure", exit_code: 1)
    assert_equal "disconnected_unproven", refine("unknown", exit_reason: "disconnected", exit_code: 0)
    assert_equal "process_failed", refine("unknown", exit_reason: "failure", exit_code: 2)
    assert_equal "unknown", refine("unknown", exit_reason: "success", exit_code: 0)
    assert_equal "boot_failure", refine("legacy_class", exit_reason: "boot_failure")
    assert_equal "unknown", refine(nil)
  end

  def test_session_that_ended_on_a_blocking_prompt_is_permission_prompt
    target = session(adapter: Harnex::Adapters::Claude.new)
    state = target.instance_variable_get(:@state_machine)
    state.update("Quick safety check: Is this a project you trust?\n❯ 1. Yes, I trust this folder\n")
    target.instance_variable_set(:@exit_reason, "disconnected")

    assert_equal :blocked, state.state
    assert_equal "permission_prompt", target.send(:refine_terminal_outcome_class, "unknown")
  end

  def test_dispatch_row_outcome_uses_the_refined_class
    target = session
    target.instance_variable_set(:@exit_reason, "boot_failure")
    target.instance_variable_set(:@exit_code, 1)

    outcome = target.send(:build_summary_outcome, nil)

    assert_equal "boot_failure", outcome["class"]
    assert_equal "unknown", outcome["status"]
  end

  def test_vocabulary_is_closed_and_includes_unknown
    assert_equal Harnex::Session::OUTCOME_CLASSES.uniq, Harnex::Session::OUTCOME_CLASSES
    assert_includes Harnex::Session::OUTCOME_CLASSES, "unknown"
    assert_empty Harnex::Session::PROCESS_OUTCOME_CLASSES - Harnex::Session::OUTCOME_CLASSES
  end
end
