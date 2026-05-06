require_relative "../../test_helper"
require "json"

class WaitUntilTaskCompleteTest < Minitest::Test
  def setup
    @repo_root = Dir.mktmpdir("harnex-wait-test")
    @id = "test-wait-tc"
    @events_path = Harnex.events_log_path(@repo_root, @id)
    FileUtils.mkdir_p(File.dirname(@events_path))
  end

  def teardown
    FileUtils.rm_rf(@repo_root)
  end

  def write_events(*events)
    File.open(@events_path, "ab") do |f|
      events.each { |e| f.write(JSON.generate(e) + "\n") }
    end
  end

  def waiter(*args)
    Harnex::Waiter.new(["--id", @id, "--repo", @repo_root, *args])
  end

  def test_returns_immediately_when_task_complete_already_present
    write_events(
      { type: "started", seq: 1 },
      { type: "task_complete", seq: 2, turnId: "trn-1" }
    )

    output, status = capture_output { waiter("--until", "task_complete").run }
    assert_equal 0, status
    payload = JSON.parse(output)
    assert payload["ok"]
    assert_equal "task_complete", payload["event"]
  end

  def test_unblocks_when_task_complete_is_appended
    write_events({ type: "started", seq: 1 })

    appender = Thread.new do
      sleep 0.2
      write_events({ type: "task_complete", seq: 2, turnId: "trn-x" })
    end

    started = Time.now
    output, status = capture_output { waiter("--until", "task_complete", "--timeout", "3").run }
    elapsed = Time.now - started
    appender.join

    assert_equal 0, status
    assert_operator elapsed, :<, 2.5, "expected unblock within 2.5s, took #{elapsed}s"
    payload = JSON.parse(output)
    assert payload["ok"]
    assert_equal "task_complete", payload["event"]
  end

  def test_timeout_returns_124
    write_events({ type: "started", seq: 1 })

    output, status = capture_output { waiter("--until", "task_complete", "--timeout", "0.3").run }
    assert_equal 124, status
    payload = JSON.parse(output)
    assert_equal "timeout", payload["status"]
  end

  def test_no_session_no_events_returns_1
    output, status = capture_output { waiter("--until", "task_complete").run }
    assert_equal 1, status
  end

  private

  def capture_output
    require "stringio"
    old_stdout = $stdout
    $stdout = StringIO.new
    status = yield
    [$stdout.string, status]
  ensure
    $stdout = old_stdout
  end
end
