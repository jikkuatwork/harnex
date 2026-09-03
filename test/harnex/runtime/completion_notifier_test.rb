require_relative "../../test_helper"
require "json"
require "shellwords"
require "stringio"

class CompletionNotifierTest < Minitest::Test
  NOW = Time.utc(2026, 9, 3, 12, 0, 12)
  PAYLOAD_KEYS = %w[
    artifact_report_status elapsed_s end_sha id notified_at outcome outcome_class
    receipt_path repo_root schema_version session_id terminal_signal work_state
  ].freeze

  def setup
    @repo = Dir.mktmpdir("harnex-completion-notifier")
    @id = "notify-#{$$}-#{rand(1_000_000)}"
    @events = []
    @warnings = StringIO.new
  end

  def teardown
    Harnex.completion_marker_paths(@repo, @id).each { |path| FileUtils.rm_f(path) }
    FileUtils.rm_rf(@repo)
  end

  def test_typed_marker_payloads_and_stale_cleanup
    Harnex.completion_marker_paths(@repo, @id).each { |path| Harnex.atomic_write_json(path, stale: true) }
    build_notifier.register!
    assert_empty Harnex.completion_marker_paths(@repo, @id).select { |path| File.exist?(path) }

    %w[completed rejected failed error].each do |outcome|
      id = "#{@id}-#{outcome}"
      notifier = build_notifier(id: id)
      notifier.register!
      assert notifier.notify(**notification_args(outcome: outcome, end_sha: "a" * 40))
      payload = JSON.parse(File.read(Harnex.completion_marker_path(@repo, id, outcome)))
      assert_equal PAYLOAD_KEYS, payload.keys.sort
      assert_equal({
        "schema_version" => 1, "id" => id, "session_id" => "session-123",
        "repo_root" => @repo, "outcome" => outcome,
        "work_state" => outcome == "completed" ? "completed" : "failed",
        "receipt_path" => File.join(@repo, "receipt.json"), "end_sha" => "a" * 40,
        "elapsed_s" => 12, "notified_at" => NOW.iso8601
      }, payload.slice("schema_version", "id", "session_id", "repo_root", "outcome",
                       "work_state", "receipt_path", "end_sha", "elapsed_s", "notified_at"))
    ensure
      Harnex.completion_marker_paths(@repo, id).each { |path| FileUtils.rm_f(path) } if id
    end
  end

  def test_sequential_and_concurrent_attempts_notify_once_without_persisting_command
    calls = []
    lock = Mutex.new
    secret = "secret-never-recorded"
    notifier = build_notifier(
      hook_command: "printf #{secret}",
      spawn: ->(env, command, options) { lock.synchronize { calls << [env, command, options] }; 12_345 },
      detach: ->(_pid) {}
    )
    notifier.register!
    assert notifier.notify(**notification_args(outcome: "completed"))
    refute notifier.notify(**notification_args(outcome: "failed"))
    2.times.map { Thread.new { notifier.notify(**notification_args(outcome: "error")) } }.each(&:join)

    notifier.register! # registration itself is one-shot and cannot erase the result
    assert_equal 1, calls.length
    assert_equal 1, Harnex.completion_marker_paths(@repo, @id).count { |path| File.exist?(path) }
    assert_equal 1, @events.count { |type, _| type == "completion_notification" }
    refute_includes File.read(Harnex.completion_marker_path(@repo, @id, "completed")), secret
    refute_includes JSON.generate(@events), secret
  end

  def test_hook_receives_environment_and_runs_from_repo_root
    sentinel = File.join(@repo, "hook.txt")
    command = "printf '%s\\n' \"$HARNEX_ID|$HARNEX_OUTCOME|$HARNEX_WORK_STATE|$HARNEX_RECEIPT_PATH|$HARNEX_END_SHA|$HARNEX_ELAPSED_S\" > #{Shellwords.shellescape(sentinel)}; pwd >> #{Shellwords.shellescape(sentinel)}"
    stderr = File.open(File::NULL, "w")
    notifier = build_notifier(hook_command: command, stderr: stderr)
    notifier.register!
    notifier.notify(**notification_args(outcome: "completed", end_sha: "b" * 40))

    assert wait_for { File.file?(sentinel) && File.readlines(sentinel).length == 2 }
    assert_equal [
      "#{@id}|completed|completed|#{File.join(@repo, 'receipt.json')}|#{'b' * 40}|12", @repo
    ], File.readlines(sentinel, chomp: true)
  ensure
    stderr&.close
  end

  def test_marker_and_hook_failures_are_loud_but_do_not_change_outcome
    hook_calls = 0
    attrs = notification_args(outcome: "rejected").freeze
    notifier = build_notifier(
      atomic_write: ->(*) { raise Errno::EACCES, "secret marker error" },
      hook_command: "echo do-not-persist-this-secret",
      spawn: ->(*) { hook_calls += 1; raise Errno::ENOENT, "secret spawn error" }
    )
    notifier.register!
    assert notifier.notify(**attrs)

    assert_equal ["rejected", 1], [attrs[:outcome], hook_calls]
    assert_match(/marker write failed.*hook launch failed/m, @warnings.string)
    refute_includes @warnings.string + JSON.generate(@events), "do-not-persist-this-secret"
    assert_equal %w[marker hook], @events.filter_map { |type, data| data[:component] if type == "completion_notification_error" }
    assert_equal [false, false], @events.last.last.values_at(:marker_written, :hook_launched)
  end

  private

  def build_notifier(id: @id, **options)
    Harnex::CompletionNotifier.new(
      repo_root: @repo, id: id, session_id: "session-123",
      receipt_path: File.join(@repo, "receipt.json"), started_at: NOW - 12.9,
      clock: -> { NOW }, event_sink: ->(type, data) { @events << [type, data] },
      stderr: @warnings, **options
    )
  end

  def notification_args(outcome:, end_sha: nil)
    {
      outcome: outcome, work_state: outcome == "completed" ? "completed" : "failed",
      outcome_class: outcome == "rejected" ? "report_rejected" : nil,
      artifact_report_status: outcome == "completed" ? "accepted" : "rejected",
      end_sha: end_sha, terminal_signal: outcome == "completed" ? "task_complete" : "task_failed"
    }
  end

  def wait_for
    deadline = Time.now + 2
    sleep 0.01 until yield || Time.now >= deadline
    yield
  end
end
