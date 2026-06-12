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

  def write_raw_event(line)
    File.open(@events_path, "ab") { |f| f.write("#{line}\n") }
  end

  def waiter(*args)
    Harnex::Waiter.new(["--id", @id, "--repo", @repo_root, *args])
  end

  def write_registry(pid:)
    Harnex.write_registry(Harnex.registry_path(@repo_root, @id), {
      "id" => @id,
      "cli" => "codex",
      "pid" => pid,
      "host" => "127.0.0.1",
      "port" => 45_000,
      "repo_root" => @repo_root,
      "events_log_path" => @events_path,
      "started_at" => Time.now.iso8601
    })
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

  def test_until_done_returns_immediately_when_task_complete_already_present
    write_registry(pid: Process.pid)
    write_events(
      { type: "started", seq: 1 },
      { type: "task_complete", seq: 2, turnId: "trn-1" }
    )

    output, status = capture_output { waiter("--until", "done").run }
    assert_equal 0, status
    payload = JSON.parse(output)
    assert payload["ok"]
    assert_equal true, payload["done"]
    assert_equal "completed", payload["work_state"]
    assert_equal "running", payload["state"]
    assert_equal "task_complete", payload["event"]
  end

  def test_until_done_returns_failure_when_task_failed_present
    write_registry(pid: Process.pid)
    write_events(
      { type: "started", seq: 1 },
      { type: "task_failed", seq: 2, turnId: "trn-f", status: "failed", message: "missing key" }
    )

    output, status = capture_output { waiter("--until", "done").run }
    assert_equal 1, status
    payload = JSON.parse(output)
    assert_equal false, payload["ok"]
    assert_equal false, payload["done"]
    assert_equal "failed", payload["work_state"]
    assert_equal "task_failed", payload["event"]
    assert_equal "missing key", payload["last_error"]
  end

  def test_ignores_terminal_words_inside_structured_event_payload
    write_events(
      {
        type: "item_completed",
        seq: 1,
        item: {
          "type" => "agentMessage",
          "text" => "The words task_complete, fail, and disconnect are just text."
        }
      }
    )

    output, status = capture_output { waiter("--until", "task_complete", "--timeout", "0.1").run }

    assert_equal 124, status
    assert_equal "timeout", JSON.parse(output)["status"]
  end

  def test_exact_legacy_task_complete_marker_still_matches
    write_raw_event("task_complete")

    output, status = capture_output { waiter("--until", "task_complete").run }

    assert_equal 0, status
    assert_equal "task_complete", JSON.parse(output)["event"]
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

  def test_drains_final_task_complete_after_process_exits
    write_registry(pid: 12_345)
    write_events({ type: "started", seq: 1 })

    appender = Thread.new do
      sleep 0.2
      write_events({ type: "task_complete", seq: 2, turnId: "trn-final" })
    end

    output, status = Harnex.stub(:alive_pid?, false) do
      capture_output { waiter("--until", "task_complete", "--timeout", "2").run }
    end
    appender.join

    assert_equal 0, status
    payload = JSON.parse(output)
    assert payload["ok"]
    assert_equal "task_complete", payload["event"]
    assert_equal 2, payload["seq"]
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
