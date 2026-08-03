require "json"
require "rbconfig"

require_relative "../test_helper"

class DispatchHistoryTest < Minitest::Test
  FakeAdapter = Struct.new(:key, keyword_init: true)
  FakeSession = Struct.new(
    :id, :session_id, :pid, :repo_root, :description, :adapter, :started_at, :ended_at,
    :exit_code, :term_signal, :events_log_path, :artifact_report_path,
    :artifact_claims_path, :git_start, :git_end,
    :task_complete, :task_failed,
    keyword_init: true
  ) do
    def task_complete?
      !!task_complete
    end

    def task_failed?
      !!task_failed
    end

    def meta_hash
      { "tier" => "B", "issue" => "21" }
    end

    def summary_tmux_session
      nil
    end

    def build_summary_record
      {
        meta: {
          "id" => id,
          "tier" => "B",
          "issue" => "21",
          "started_at" => started_at&.iso8601,
          "ended_at" => ended_at&.iso8601
        },
        predicted: {},
        actual: { "exit" => "success", "exit_code" => exit_code, "task_complete" => task_complete? },
        agent: { "cli" => adapter.key },
        usage: { "status" => "unsupported" },
        context: { "status" => "unsupported" },
        attribution: { "status" => "unattributed" },
        outcome: { "status" => "no_change", "class" => "unknown" },
        attempt: { "run_id" => id, "kind" => "initial", "status" => "succeeded" },
        reliability: { "recovered" => false }
      }
    end
  end

  SECTION_KEYS = %w[
    actual agent attempt attribution context meta outcome predicted reliability usage
  ].freeze

  def test_schema_round_trip
    session = fake_session(
      task_complete: true,
      git_start: { sha: "a" * 40 },
      git_end: { sha: "b" * 40 }
    )

    record = JSON.parse(JSON.generate(Harnex::DispatchHistory.build_record(session)))

    {
      "schema_version" => 2,
      "record_type" => "dispatch_end",
      "id" => "cx-history",
      "session_id" => "sess-1",
      "description" => "history test",
      "cli" => "codex",
      "status" => "completed",
      "terminal_event" => "task_complete",
      "commit_sha" => "b" * 40,
      "tier" => "B",
      "events_log_path" => "/tmp/events.log",
      "tmux_state" => "torn-down"
    }.each { |key, value| assert_equal value, record.fetch(key) }

    # The rich summary sections ride alongside the envelope; the thin raw
    # meta passthrough is replaced by the summary's meta section.
    SECTION_KEYS.each { |key| assert record.key?(key), "expected section #{key}" }
    assert_equal "cx-history", record.dig("meta", "id")
    assert_equal "B", record.dig("meta", "tier")
    assert_equal "success", record.dig("actual", "exit")
  end

  def test_start_record_schema
    session = fake_session
    record = JSON.parse(JSON.generate(Harnex::DispatchHistory.build_start_record(session)))

    assert_equal %w[
      artifact_claims_path artifact_report_path cli description events_log_path
      host id meta pid record_type repo_root schema_version session_id started_at
      tier
    ], record.keys.sort

    assert_equal 2, record.fetch("schema_version")
    assert_equal "dispatch_start", record.fetch("record_type")
    assert_equal "cx-history", record.fetch("id")
    assert_equal "sess-1", record.fetch("session_id")
    assert_equal 4242, record.fetch("pid")
    assert_equal "codex", record.fetch("cli")
    assert_equal "/tmp/repo", record.fetch("repo_root")
    assert_equal "2026-05-08T06:18:45Z", record.fetch("started_at")
    assert_equal "B", record.fetch("tier")
    assert_equal({ "tier" => "B", "issue" => "21" }, record.fetch("meta"))
  end

  def test_end_record_completes_start_record
    start = JSON.parse(JSON.generate(Harnex::DispatchHistory.build_start_record(fake_session)))
    finish = JSON.parse(JSON.generate(Harnex::DispatchHistory.build_record(fake_session)))

    assert Harnex::DispatchHistory.start_record?(start)
    refute Harnex::DispatchHistory.end_record?(start)
    assert Harnex::DispatchHistory.end_record?(finish)
    assert Harnex::DispatchHistory.end_matches_start?(finish, start)
  end

  def test_legacy_end_record_pairs_by_id_and_started_at
    start = JSON.parse(JSON.generate(Harnex::DispatchHistory.build_start_record(fake_session)))
    legacy = JSON.parse(JSON.generate(Harnex::DispatchHistory.build_record(fake_session)))
    legacy.delete("record_type")
    legacy.delete("session_id")
    legacy["schema_version"] = 1

    assert Harnex::DispatchHistory.end_record?(legacy)
    assert Harnex::DispatchHistory.end_matches_start?(legacy, start)

    other = legacy.merge("started_at" => "2026-05-08T09:00:00Z")
    refute Harnex::DispatchHistory.end_matches_start?(other, start)
  end

  def test_latest_rows_pairs_v1_and_v2_rows_in_one_file
    Dir.mktmpdir("harnex-history-mixed") do |repo|
      init_git_repo(repo)
      path = Harnex::DispatchHistory.path_for(repo)

      # v1-era pair: thin end row without record_type (legacy clause).
      Harnex::DispatchHistory.append(path, {
        schema_version: 1, record_type: "dispatch_start", id: "cx-v1",
        session_id: "", pid: 1, started_at: "2026-05-01T06:00:00Z"
      })
      Harnex::DispatchHistory.append(path, history_record("cx-v1", "2026-05-01T06:00:00Z"))

      # v2 pair from the current builders.
      v2 = fake_session(id: "cx-v2", session_id: "sess-v2")
      Harnex::DispatchHistory.append(path, Harnex::DispatchHistory.build_start_record(v2))
      Harnex::DispatchHistory.append(path, Harnex::DispatchHistory.build_record(v2))

      v1_rows = Harnex::DispatchHistory.latest_rows(path, "cx-v1")
      assert v1_rows[:start]
      assert v1_rows[:end]
      assert_equal 1, v1_rows[:end]["schema_version"]

      v2_rows = Harnex::DispatchHistory.latest_rows(path, "cx-v2")
      assert v2_rows[:start]
      assert v2_rows[:end]
      assert_equal 2, v2_rows[:end]["schema_version"]
      assert_kind_of Hash, v2_rows[:end]["actual"]
    end
  end

  def test_live_start_record_reports_running_unpaired_start_row
    Dir.mktmpdir("harnex-history-live") do |repo|
      init_git_repo(repo)
      path = Harnex::DispatchHistory.path_for(repo)
      session = fake_session(pid: Process.pid)
      Harnex::DispatchHistory.append(path, Harnex::DispatchHistory.build_start_record(session))

      live = Harnex::DispatchHistory.live_start_record(repo_root: repo, id: "cx-history")
      assert live
      assert_equal "sess-1", live["session_id"]

      Harnex::DispatchHistory.append(path, Harnex::DispatchHistory.build_record(session))
      assert_nil Harnex::DispatchHistory.live_start_record(repo_root: repo, id: "cx-history")
    end
  end

  def test_live_start_record_ignores_dead_pids_and_foreign_hosts
    Dir.mktmpdir("harnex-history-live-dead") do |repo|
      init_git_repo(repo)
      path = Harnex::DispatchHistory.path_for(repo)

      dead_pid = spawn("true")
      Process.wait(dead_pid)
      dead = Harnex::DispatchHistory.build_start_record(fake_session(pid: dead_pid))
      Harnex::DispatchHistory.append(path, dead)
      assert_nil Harnex::DispatchHistory.live_start_record(repo_root: repo, id: "cx-history")

      foreign = Harnex::DispatchHistory.build_start_record(fake_session(id: "cx-foreign", pid: Process.pid))
      foreign[:host] = "some-other-host"
      Harnex::DispatchHistory.append(path, foreign)
      assert_nil Harnex::DispatchHistory.live_start_record(repo_root: repo, id: "cx-foreign")
    end
  end

  def test_path_resolution_handles_repo_deep_tree_and_global_fallback
    Dir.mktmpdir("harnex-history-deep") do |repo|
      init_git_repo(repo)
      nested = (1..9).reduce(repo) { |path, index| File.join(path, "d#{index}") }
      FileUtils.mkdir_p(nested)

      assert_equal repo, Harnex::DispatchHistory.find_git_root(nested)
      assert_equal File.join(repo, ".harnex", "dispatch.jsonl"), Harnex::DispatchHistory.path_for(nested)
    end

    Dir.mktmpdir("harnex-history-no-git") do |dir|
      nested = (1..11).reduce(dir) { |path, index| File.join(path, "d#{index}") }
      FileUtils.mkdir_p(nested)

      assert_equal Harnex::DispatchHistory.global_path, Harnex::DispatchHistory.path_for(nested)
    end
  end

  def test_status_classification
    {
      { task_failed: true, exit_code: 0 } => ["failed", "task_failed"],
      { task_complete: true } => ["completed", "task_complete"],
      { exit_code: 124 } => ["timeout", "timeout"],
      { term_signal: 15 } => ["killed", "process_kill"],
      { exit_code: 1 } => ["failed", "dispatch_failed"]
    }.each do |attrs, expected|
      assert_equal expected, Harnex::DispatchHistory.classify(fake_session(**attrs))
    end
  end

  def test_commit_sha_detection_for_head_change_no_change_and_dirty_state
    Dir.mktmpdir("harnex-history-git") do |repo|
      init_git_repo(repo)
      start = Harnex.git_capture_start(repo)

      assert_nil Harnex::DispatchHistory.commit_sha(start, Harnex.git_capture_end(repo, start[:sha]))

      File.write(File.join(repo, "dirty.txt"), "dirty\n")
      assert_nil Harnex::DispatchHistory.commit_sha(start, Harnex.git_capture_end(repo, start[:sha]))

      commit_file(repo, "two.txt", "two\n", "second")
      head = git(repo, "rev-parse", "HEAD")
      assert_equal head, Harnex::DispatchHistory.commit_sha(start, Harnex.git_capture_end(repo, start[:sha]))
    end
  end

  def test_history_command_outputs_jsonl_with_limit
    Dir.mktmpdir("harnex-history-command") do |repo|
      init_git_repo(repo)
      path = Harnex::DispatchHistory.path_for(repo)
      Harnex::DispatchHistory.append(path, history_record("first", "2026-05-08T06:00:00Z"))
      Harnex::DispatchHistory.append(path, history_record("second", "2026-05-08T07:00:00Z"))

      Dir.chdir(repo) do
        out, = capture_io { assert_equal 0, Harnex::History.new(["--limit", "1", "--json"]).run }
        rows = out.lines.map { |line| JSON.parse(line) }

        assert_equal ["second"], rows.map { |row| row.fetch("id") }
      end
    end
  end

  def test_history_command_shows_running_and_interrupted_rows_for_unpaired_starts
    Dir.mktmpdir("harnex-history-running") do |repo|
      init_git_repo(repo)
      path = Harnex::DispatchHistory.path_for(repo)

      # Completed dispatch: start + end pair renders one end row.
      done = fake_session(id: "cx-done", session_id: "sess-done")
      Harnex::DispatchHistory.append(path, Harnex::DispatchHistory.build_start_record(done))
      Harnex::DispatchHistory.append(path, Harnex::DispatchHistory.build_record(done))

      # Mid-run dispatch: unpaired start row with an alive pid.
      running = fake_session(id: "cx-running", session_id: "sess-running", pid: Process.pid)
      Harnex::DispatchHistory.append(path, Harnex::DispatchHistory.build_start_record(running))

      # Crashed dispatch: unpaired start row with a dead pid.
      dead_pid = spawn("true")
      Process.wait(dead_pid)
      crashed = fake_session(id: "cx-crashed", session_id: "sess-crashed", pid: dead_pid)
      Harnex::DispatchHistory.append(path, Harnex::DispatchHistory.build_start_record(crashed))

      Dir.chdir(repo) do
        out, = capture_io { assert_equal 0, Harnex::History.new(["--json", "--all"]).run }
        rows = out.lines.map { |line| JSON.parse(line) }

        assert_equal %w[cx-done cx-running cx-crashed], rows.map { |row| row.fetch("id") }

        done_row = rows.find { |row| row["id"] == "cx-done" }
        assert_equal "dispatch_end", done_row["record_type"]
        assert_equal "completed", done_row["status"]

        running_row = rows.find { |row| row["id"] == "cx-running" }
        assert_equal "dispatch_start", running_row["record_type"]
        assert_equal "running", running_row["status"]
        assert_kind_of Integer, running_row["duration_s"]
        assert_nil running_row["ended_at"]

        crashed_row = rows.find { |row| row["id"] == "cx-crashed" }
        assert_equal "interrupted", crashed_row["status"]
      end
    end
  end

  def test_history_command_skips_unrecognized_legacy_schema_rows
    Dir.mktmpdir("harnex-history-legacy") do |repo|
      init_git_repo(repo)
      path = Harnex::DispatchHistory.path_for(repo)

      # Pre-0.7.3 telemetry schema: no top-level id/record_type/schema_version.
      Harnex::DispatchHistory.append(path, {
        meta: { id: "cx-old", started_at: "2026-05-09T21:20:45+05:30" },
        predicted: {},
        actual: { duration_s: 403, exit: "success" }
      })
      Harnex::DispatchHistory.append(path, history_record("current", "2026-05-08T06:00:00Z"))
      Harnex::DispatchHistory.append(path, Harnex::DispatchHistory.build_record(fake_session(id: "cx-v2")))

      Dir.chdir(repo) do
        out, = capture_io { assert_equal 0, Harnex::History.new(["--json", "--all"]).run }
        rows = out.lines.map { |line| JSON.parse(line) }
        assert_equal %w[current cx-v2], rows.map { |row| row.fetch("id") }

        table, = capture_io { assert_equal 0, Harnex::History.new(["--all"]).run }
        data_lines = table.lines.drop(1)
        assert_equal 2, data_lines.size
        assert_match(/\Acurrent\b/, data_lines.first)
        assert_match(/\Acx-v2\b/, data_lines.last)
      end
    end
  end

  def test_run_writes_repo_local_dispatch_history
    Dir.mktmpdir("harnex-history-run") do |repo|
      init_git_repo(repo)
      script = ""

      Dir.chdir(repo) do
        _, err = capture_io do
          assert_equal 0, Harnex::Runner.new([
            RbConfig.ruby,
            "--id", "cx-run-history",
            "--description", "run history",
            "--meta", '{"tier":"B"}',
            "--", "-e", script
          ]).run
        end
        assert_match(/harnex: session cx-run-history/, err)
      end

      path = File.join(repo, ".harnex", "dispatch.jsonl")
      rows = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[dispatch_start dispatch_end], rows.map { |row| row.fetch("record_type") }

      record = rows.last
      assert_equal "cx-run-history", record.fetch("id")
      assert_equal "completed", record.fetch("status")
      assert_equal "B", record.fetch("tier")
      assert_equal Harnex.events_log_path(repo, "cx-run-history"), record.fetch("events_log_path")
      assert_equal 2, record.fetch("schema_version")
      SECTION_KEYS.each { |key| assert record.key?(key), "expected section #{key}" }
      refute record.key?("summary_out_path"), "removed mirror key must not reappear"
    end
  end

  def test_run_history_uses_launch_cwd_when_child_changes_directory
    Dir.mktmpdir("harnex-history-cross-repo") do |root|
      source_repo = File.join(root, "source")
      launch_repo = File.join(root, "launch")
      worker_repo = File.join(root, "worker")
      init_git_repo(source_repo)
      assert system("git", "-C", source_repo, "worktree", "add", "-q", "-b", "launch", launch_repo, "HEAD")
      init_git_repo(worker_repo)
      script = "Dir.chdir(ARGV.fetch(0))"

      Dir.chdir(launch_repo) do
        _, err = capture_io do
          assert_equal 0, Harnex::Runner.new([
            RbConfig.ruby,
            "--id", "cx-run-cross-history",
            "--description", "cross repo history",
            "--meta", '{"tier":"B"}',
            "--", "-e", script, worker_repo
          ]).run
        end
        assert_match(/harnex: session cx-run-cross-history/, err)
      end

      launch_path = File.join(launch_repo, ".harnex", "dispatch.jsonl")
      worker_path = File.join(worker_repo, ".harnex", "dispatch.jsonl")
      record = JSON.parse(File.readlines(launch_path, chomp: true).last)

      assert_equal "cx-run-cross-history", record.fetch("id")
      assert_equal "completed", record.fetch("status")
      assert_equal Harnex.events_log_path(launch_repo, "cx-run-cross-history"), record.fetch("events_log_path")
      refute_path_exists worker_path
    end
  end

  private

  def fake_session(overrides = {})
    defaults = {
      id: "cx-history",
      session_id: "sess-1",
      pid: 4242,
      repo_root: "/tmp/repo",
      description: "history test",
      adapter: FakeAdapter.new(key: "codex"),
      started_at: Time.utc(2026, 5, 8, 6, 18, 45),
      ended_at: Time.utc(2026, 5, 8, 6, 32, 12),
      exit_code: 0,
      term_signal: nil,
      events_log_path: "/tmp/events.log",
      artifact_report_path: "/tmp/receipt.json",
      artifact_claims_path: "/tmp/receipt.json.claims.json",
      git_start: {},
      git_end: {},
      task_complete: false,
      task_failed: false
    }
    FakeSession.new(**defaults.merge(overrides))
  end

  def history_record(id, started_at)
    {
      schema_version: 1, id: id, description: nil, cli: "codex",
      started_at: started_at, ended_at: started_at, duration_s: 0,
      status: "completed", terminal_event: "task_complete", commit_sha: nil,
      tier: nil, meta: {}, events_log_path: "/tmp/events.log",
      tmux_state: "torn-down"
    }
  end

  def init_git_repo(repo)
    system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
    commit_file(repo, "README.md", "one\n", "initial")
  end

  def commit_file(repo, relative_path, content, message)
    File.write(File.join(repo, relative_path), content)
    system("git", "-C", repo, "add", relative_path, out: File::NULL, err: File::NULL)
    system(
      "git", "-C", repo,
      "-c", "user.email=test@example.com",
      "-c", "user.name=Test",
      "commit", "-q", "-m", message,
      out: File::NULL, err: File::NULL
    )
  end

  def git(repo, *args)
    output, status = Open3.capture2("git", "-C", repo, *args)
    raise "git #{args.join(' ')} failed" unless status.success?

    output.strip
  end
end
