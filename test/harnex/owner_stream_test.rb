require_relative "../test_helper"
require "securerandom"
require "stringio"

# #77: `harnex watch --owner` lifecycle lines over real #72 owner records.
class OwnerStreamTest < Minitest::Test
  def setup
    @owner = "claude-#{SecureRandom.hex(4)}"
    @repo = Dir.mktmpdir("harnex-owner-stream")
    system("git", "init", "-q", @repo, out: File::NULL, err: File::NULL)
    @out = StringIO.new
    @now = Time.now
  end

  def teardown
    FileUtils.rm_rf(Harnex.owned_notifications_dir(@owner))
    FileUtils.rm_rf(@repo)
  end

  def notifier(id, session_id = SecureRandom.hex(8))
    Harnex::CompletionNotifier.new(
      repo_root: @repo, id: id, session_id: session_id, receipt_path: File.join(@repo, "#{id}.json"),
      owner_id: @owner, started_at: @now - 734, stderr: StringIO.new
    ).tap(&:register!)
  end

  def settle(notifier, outcome, outcome_class: nil)
    notifier.notify(outcome: outcome, work_state: outcome == "completed" ? "completed" : "failed",
                    outcome_class: outcome_class, artifact_report_status: nil, end_sha: nil,
                    terminal_signal: outcome == "completed" ? "task_complete" : "finalization")
  end

  def stream(**options)
    Harnex::OwnerStream.new(owner_id: @owner, out: @out, err: StringIO.new, wall_clock: -> { @now }, **options)
  end

  def lines
    @out.string.lines.map { |line| JSON.parse(line) }.tap { @out.truncate(0) && @out.rewind }
  end

  def test_started_then_done_once_with_readable_msg
    worker = notifier("pi-i-42")
    s = stream
    s.scan
    started = only(lines)
    assert_equal %w[harnex.owner_event.v1 started pi-i-42 running],
                 started.values_at("schema", "event", "id", "work_state")
    assert_includes started["msg"], "pi-i-42 started in"

    settle(worker, "completed", outcome_class: "completed_with_proof")
    s.scan
    done = only(lines)
    assert_equal "done", done["event"]
    assert_equal "pi-i-42 done (completed_with_proof) after 12m", done["msg"]
    assert_equal 734, done["elapsed_s"]

    s.scan
    assert_empty lines, "no heartbeats and no repeats"
  end

  def test_restart_replays_running_but_never_repeats_delivered_results
    finished = notifier("pi-i-1")
    settle(finished, "completed", outcome_class: "completed_with_proof")
    notifier("pi-i-2")
    stream.scan
    assert_equal [%w[done pi-i-1], %w[started pi-i-2]], lines.map { |line| line.values_at("event", "id") }.sort

    stream.scan
    assert_equal [%w[started pi-i-2]], lines.map { |line| line.values_at("event", "id") },
                 "a restarted stream re-announces running work only"
  end

  def test_rejected_and_failed_settlements
    rejected = notifier("pi-r-1")
    failed_session = SecureRandom.hex(8)
    failed = notifier("pi-f-1", failed_session)
    settle(rejected, "rejected", outcome_class: "report_missing")
    settle(failed, "failed", outcome_class: "task_failed")
    append_row(failed_session, "task_failed")
    stream.scan

    by_id = lines.to_h { |line| [line["id"], line] }
    assert_equal "rejected", by_id["pi-r-1"]["event"]
    assert_equal "pi-r-1 rejected: report_missing after 12m", by_id["pi-r-1"]["msg"]
    assert_equal "failed", by_id["pi-f-1"]["event"]
  end

  def test_error_settlements_use_the_dispatch_row_class
    { "pi-t-1" => %w[timeout timeout], "pi-s-1" => %w[stopped_by_caller stopped], "pi-b-1" => %w[boot_failure failed] }
      .each do |id, (row_class, _event)|
        session_id = SecureRandom.hex(8)
        settle(notifier(id, session_id), "error")
        append_row(session_id, row_class)
      end
    stream.scan

    events = lines.to_h { |line| [line["id"], line.values_at("event", "outcome_class")] }
    assert_equal %w[timeout timeout], events["pi-t-1"]
    assert_equal %w[stopped stopped_by_caller], events["pi-s-1"]
    assert_equal %w[failed boot_failure], events["pi-b-1"]
  end

  # Live finding: Pi settles a manually stopped turn as "failed"
  # (task_failed), not "error"; the row still names stopped_by_caller.
  def test_failed_settlement_of_a_stopped_pi_turn_reports_stopped
    session_id = SecureRandom.hex(8)
    settle(notifier("pi-c-1", session_id), "failed")
    append_row(session_id, "stopped_by_caller")
    stream.scan

    line = only(lines)
    assert_equal %w[stopped stopped_by_caller], line.values_at("event", "outcome_class")
    assert_equal "pi-c-1 stopped by its caller after 12m", line["msg"]
  end

  def test_error_settlement_waits_briefly_for_its_row_then_reports_failed
    settle(notifier("pi-e-1"), "error")
    s = stream
    s.scan
    assert_empty lines, "row not written yet: wait for it"

    @now += Harnex::OwnerStream::ROW_GRACE_S + 1
    s.scan
    assert_equal ["failed"], lines.map { |line| line["event"] }
  end

  def test_a_runner_that_died_without_settling_is_reported_once
    dead = spawn("true")
    Process.wait(dead)
    session_id = SecureRandom.hex(8)
    Harnex.atomic_write_json(Harnex.owned_notification_path(@owner, session_id), {
      schema_version: 1, owner_id: @owner, id: "pi-g-1", session_id: session_id,
      repo_root: @repo, runner_pid: dead, started_at: @now.utc.iso8601, work_state: "running"
    })
    stream.scan
    assert_equal [%w[started pi-g-1], %w[failed runner_gone]], lines.map { |line| [line["event"], line["reason"] || line["id"]] }

    stream.scan
    assert_equal [], lines, "delivered once, not on every restart"
  end

  def test_stall_fires_once_per_episode_and_rearms_after_progress
    notifier("pi-st-1")
    idle = 1600.0
    payload = lambda do |_record|
      { "work_state" => "running", "activity" => {
        "status" => "observed", "turn_active" => true, "turn_age_s" => idle + 100, "model_idle_s" => idle, "tool_idle_s" => idle + 50
      } }
    end
    clock = 0.0
    s = stream(stall_after: 1500.0, status_fetcher: payload, clock: -> { clock })

    s.scan
    assert_equal %w[started stalled], lines.map { |line| line["event"] }
    clock += 400
    s.scan
    assert_empty lines, "still the same stall episode"

    idle = 10.0
    clock += 400
    s.scan
    idle = 1700.0
    clock += 400
    s.scan
    stalled = only(lines)
    assert_equal "stalled", stalled["event"]
    assert_equal({ "clock" => "activity", "idle_s" => 1700.0, "threshold_s" => 1500.0 }, stalled["stall"])
    assert_equal "pi-st-1 stalled: no progress for 28m (activity)", stalled["msg"]
  end

  def test_foreign_or_malformed_records_are_ignored
    dir = Harnex.owned_notifications_dir(@owner)
    FileUtils.mkdir_p(File.join(dir, "consumer"))
    File.write(File.join(dir, "garbage.json"), "{not json")
    Harnex.atomic_write_json(File.join(dir, "other.json"), { owner_id: "someone-else", id: "x", session_id: "y" })
    File.write(File.join(dir, "consumer", "ack.json"), "{}")
    stream.scan

    assert_empty lines
  end

  def test_max_wait_ends_the_stream_with_124
    clock = 0.0
    s = Harnex::OwnerStream.new(owner_id: @owner, max_wait: 5, out: @out, err: StringIO.new,
                                clock: -> { clock }, sleeper: ->(seconds) { clock += seconds })
    assert_equal 124, s.run
  end

  def test_watch_owner_defaults_to_the_ambient_claude_session_and_validates_flags
    captured = nil
    stub_new = lambda do |**kwargs|
      captured = kwargs
      Struct.new(:run).new(0)
    end
    with_env("CLAUDE_CODE_SESSION_ID" => @owner) do
      Harnex::OwnerStream.stub(:new, stub_new) do
        assert_equal 0, Harnex::WatchCommand.new(["--owner", "--stall-after", "25m"]).run
      end
    end
    assert_equal @owner, captured[:owner_id]
    assert_equal 1500.0, captured[:stall_after]

    assert_raises(OptionParser::InvalidOption) { Harnex::WatchCommand.new(["--owner", "x", "--id", "y"]).run }
    assert_raises(OptionParser::InvalidOption) { Harnex::WatchCommand.new(["--owner", "x", "--done-marker", "/tmp/m"]).run }
  end

  def test_a_nudged_turn_reports_its_own_result_once
    worker = notifier("pi-n-1")
    s = stream
    s.scan
    assert_equal "started", only(lines)["event"]
    settle(worker, "failed", outcome_class: "task_failed")
    @now += 10
    s.scan
    assert_equal "failed", only(lines)["event"]

    worker.turn_started(2)
    s.scan
    assert_empty lines, "a nudged turn starts silently"

    settle_turn(worker, "completed", 2, outcome_class: "completed_with_activity",
                follow_ups: { sent: 1, pending: 0 })
    s.scan
    done = only(lines)
    assert_equal ["done", 2], done.values_at("event", "turn")
    assert_operator done["elapsed_s"], :<, 60, "a later turn is timed from its own start"
    assert_match(/\Api-n-1 turn 2 done \(completed_with_activity\) after \d+s\z/, done["msg"])
    assert_equal({ "sent" => 1, "pending" => 0 }, done["follow_ups"])
    refute_nil done["settled_at"]

    stream.scan
    assert_empty lines, "a restarted stream does not repeat the turn"
  end

  def test_a_pre_turn_cursor_still_matches_first_turn_results
    worker = notifier("pi-c-1")
    settle(worker, "completed", outcome_class: "completed_with_proof")
    record = JSON.parse(File.read(Dir.glob(File.join(Harnex.owned_notifications_dir(@owner), "*.json")).first))
    cursor = File.join(Harnex.owned_notifications_dir(@owner), "watch", "cursor.json")
    FileUtils.mkdir_p(File.dirname(cursor))
    Harnex.atomic_write_json(cursor, { schema_version: 1, delivered: { record["session_id"] => record["notified_at"] } })

    stream.scan
    assert_empty lines
  end

  def test_once_returns_the_first_result_and_skips_started
    notifier("pi-o-1")
    finished = notifier("pi-o-2")
    settle(finished, "completed", outcome_class: "completed_with_proof")
    second = notifier("pi-o-3")
    settle(second, "completed", outcome_class: "completed_with_proof")

    assert_equal 0, stream(once: true, sleeper: ->(_s) { flunk "should not sleep" }).run
    first = only(lines)
    assert_equal "done", first["event"]

    assert_equal 0, stream(once: true, sleeper: ->(_s) { flunk "should not sleep" }).run
    second_line = only(lines)
    assert_equal "done", second_line["event"]
    refute_equal first["id"], second_line["id"]

    clock = 0.0
    timed = stream(once: true, max_wait: 5, clock: -> { clock }, sleeper: ->(seconds) { clock += seconds })
    assert_equal 124, timed.run
    assert_empty lines, "only running work remains; started never ends a --once call"
  end

  def test_named_cursors_deliver_independently
    worker = notifier("pi-k-1")
    settle(worker, "completed", outcome_class: "completed_with_proof")

    assert_equal 0, stream(once: true, cursor: "parent").run
    assert_equal "done", only(lines)["event"]
    assert_equal 0, stream(once: true, cursor: "sub-a").run
    assert_equal "done", only(lines)["event"]
    assert_raises(ArgumentError) { stream(cursor: "../x") }
  end

  def test_once_keeps_a_stall_episode_across_calls
    notifier("pi-os-1")
    idle = 1600.0
    payload = lambda do |_record|
      { "work_state" => "running", "activity" => {
        "status" => "observed", "turn_active" => true, "turn_age_s" => idle + 100, "model_idle_s" => idle, "tool_idle_s" => idle + 50
      } }
    end
    clock = 0.0
    call = lambda do
      stream(once: true, stall_after: 1500.0, max_wait: 5, status_fetcher: payload,
             clock: -> { clock }, sleeper: ->(seconds) { clock += seconds }).run
    end

    assert_equal 0, call.call
    assert_equal "stalled", only(lines)["event"]
    assert_equal 124, call.call, "the same episode does not end the next call"
    assert_empty lines

    idle = 10.0
    assert_equal 124, call.call
    idle = 1700.0
    assert_equal 0, call.call
    assert_equal "stalled", only(lines)["event"]
  end

  def test_watch_once_and_cursor_need_owner
    assert_raises(OptionParser::InvalidOption) { Harnex::WatchCommand.new(["--id", "x", "--once"]).run }
    assert_raises(OptionParser::InvalidArgument) { Harnex::WatchCommand.new(["--owner", "x", "--cursor", "a/b"]).run }
  end

  private

  def settle_turn(notifier, outcome, turn, outcome_class: nil, follow_ups: nil)
    notifier.notify(outcome: outcome, work_state: outcome == "completed" ? "completed" : "failed",
                    outcome_class: outcome_class, artifact_report_status: nil, end_sha: nil,
                    terminal_signal: "task_complete", turn: turn, follow_ups: follow_ups)
  end

  def only(list)
    assert_equal 1, list.length, list.inspect
    list.first
  end

  def append_row(session_id, outcome_class)
    Harnex::DispatchHistory.append(Harnex::DispatchHistory.path_for(@repo), {
      schema_version: 2, record_type: "dispatch_end", id: "row", session_id: session_id,
      status: "failed", outcome: { class: outcome_class }
    })
  end

  def with_env(overrides)
    saved = overrides.keys.to_h { |key| [key, ENV[key]] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
