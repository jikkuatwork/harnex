require "json"
require "rbconfig"

require_relative "../test_helper"

class DispatchHistoryTest < Minitest::Test
  FakeAdapter = Struct.new(:key, keyword_init: true)
  FakeSession = Struct.new(
    :id, :description, :adapter, :started_at, :ended_at, :exit_code, :term_signal,
    :summary_out, :events_log_path, :git_start, :git_end, :task_complete, :task_failed,
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
  end

  def test_schema_round_trip
    session = fake_session(
      task_complete: true,
      git_start: { sha: "a" * 40 },
      git_end: { sha: "b" * 40 }
    )

    record = JSON.parse(JSON.generate(Harnex::DispatchHistory.build_record(session)))

    {
      "schema_version" => 1,
      "id" => "cx-history",
      "description" => "history test",
      "cli" => "codex",
      "status" => "completed",
      "terminal_event" => "task_complete",
      "commit_sha" => "b" * 40,
      "tier" => "B",
      "meta" => { "tier" => "B", "issue" => "21" },
      "summary_out_path" => "tmp/summary.jsonl",
      "events_log_path" => "/tmp/events.log",
      "tmux_state" => "torn-down"
    }.each { |key, value| assert_equal value, record.fetch(key) }
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
      record = JSON.parse(File.readlines(path, chomp: true).last)
      assert_equal "cx-run-history", record.fetch("id")
      assert_equal "completed", record.fetch("status")
      assert_equal "B", record.fetch("tier")
      assert_equal Harnex.events_log_path(repo, "cx-run-history"), record.fetch("events_log_path")
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
      description: "history test",
      adapter: FakeAdapter.new(key: "codex"),
      started_at: Time.utc(2026, 5, 8, 6, 18, 45),
      ended_at: Time.utc(2026, 5, 8, 6, 32, 12),
      exit_code: 0,
      term_signal: nil,
      summary_out: "tmp/summary.jsonl",
      events_log_path: "/tmp/events.log",
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
      tier: nil, meta: {}, summary_out_path: nil, events_log_path: "/tmp/events.log",
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
