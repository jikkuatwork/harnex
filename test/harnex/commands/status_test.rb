require_relative "../../test_helper"

class StatusCommandTest < Minitest::Test
  def setup
    @repo_root = Dir.pwd
    @created_paths = []
    @created_dirs = []
  end

  def teardown
    @created_paths.each { |path| FileUtils.rm_f(path) }
    @created_dirs.each { |dir| FileUtils.rm_rf(dir) }
  end

  def test_status_json_outputs_array
    write_registry("alpha", description: "first session")

    status = Harnex::Status.new(["--json"])
    out, = capture_io { assert_equal 0, status.run }
    data = JSON.parse(out)

    assert_kind_of Array, data
    assert_equal "alpha", data.first["id"]
    assert_equal "first session", data.first["description"]
  end

  def test_status_json_includes_log_activity_keys_with_null_and_non_null_values
    write_registry("alpha", include_log_keys: true, log_mtime: nil, log_idle_s: nil)
    write_registry("beta", include_log_keys: true, log_mtime: Time.now.iso8601, log_idle_s: 9)

    status = Harnex::Status.new(["--json"])
    out, = capture_io { assert_equal 0, status.run }
    data = JSON.parse(out)
    alpha = data.find { |row| row["id"] == "alpha" }
    beta = data.find { |row| row["id"] == "beta" }

    refute_nil alpha
    refute_nil beta
    assert alpha.key?("log_mtime")
    assert alpha.key?("log_idle_s")
    assert_nil alpha["log_mtime"]
    assert_nil alpha["log_idle_s"]
    assert_kind_of String, beta["log_mtime"]
    assert_kind_of Integer, beta["log_idle_s"]
  end

  def test_status_id_filters_results
    write_registry("alpha")
    write_registry("beta")

    status = Harnex::Status.new(["--json", "--id", "beta"])
    out, = capture_io { assert_equal 0, status.run }
    data = JSON.parse(out)

    assert_equal 1, data.length
    assert_equal "beta", data.first["id"]
  end

  def test_status_table_includes_repo_column
    write_registry("gamma")

    status = Harnex::Status.new([])
    out, = capture_io { assert_equal 0, status.run }

    assert_includes out, "REPO"
  end

  def test_status_json_includes_work_done_for_live_task_complete_session
    write_registry("holm-worker", last_completed_at: Time.now.iso8601)

    status = Harnex::Status.new(["--json", "--id", "holm-worker"])
    out, = capture_io { assert_equal 0, status.run }
    data = JSON.parse(out)

    assert_equal 1, data.length
    assert_equal "running", data.first["state"]
    assert_equal "running", data.first["process_state"]
    assert_equal false, data.first["terminal"]
    assert_equal true, data.first["task_complete"]
    assert_equal true, data.first["done"]
    assert_equal "completed", data.first["work_state"]
  end

  def test_status_json_id_returns_terminal_summary_when_session_is_not_active
    repo = create_git_repo
    dispatch_path = File.join(repo, ".harnex", "dispatch.jsonl")
    FileUtils.mkdir_p(File.dirname(dispatch_path))
    File.write(dispatch_path, JSON.generate({
      "meta" => {
        "id" => "done-48",
        "repo" => repo,
        "started_at" => Time.now.iso8601,
        "ended_at" => Time.now.iso8601
      },
      "actual" => {
        "task_complete" => true,
        "exit" => "success",
        "exit_code" => 0
      },
      "predicted" => {}
    }) + "\n")

    status = Harnex::Status.new(["--json", "--repo", repo, "--id", "done-48"])
    out, = capture_io { assert_equal 0, status.run }
    data = JSON.parse(out)

    assert_equal 1, data.length
    assert_equal "done-48", data.first["id"]
    assert_equal "completed", data.first["state"]
    assert_equal "exited", data.first["process_state"]
    assert_equal true, data.first["terminal"]
    assert_equal true, data.first["done"]
    assert_equal "completed", data.first["work_state"]
    assert_equal "success", data.first["exit"]
    assert_equal 0, data.first["exit_code"]
  end

  def test_status_json_id_returns_unknown_when_no_live_or_terminal_data_exists
    repo = create_git_repo

    status = Harnex::Status.new(["--json", "--repo", repo, "--id", "ghost-48"])
    out, = capture_io { assert_equal 0, status.run }
    data = JSON.parse(out)

    assert_equal 1, data.length
    assert_equal "ghost-48", data.first["id"]
    assert_equal "unknown", data.first["state"]
    assert_equal "unknown", data.first["process_state"]
    assert_equal false, data.first["terminal"]
    assert_equal false, data.first["done"]
    assert_equal "unknown", data.first["work_state"]
  end

  def test_status_table_includes_idle_column_and_nil_fallback
    write_registry("gamma", include_log_keys: true, log_mtime: nil, log_idle_s: nil)

    status = Harnex::Status.new([])
    out, = capture_io { assert_equal 0, status.run }

    lines = out.lines.map(&:rstrip)
    headers = lines.fetch(0).split(/\s{2,}/)
    row = lines.fetch(2).split(/\s{2,}/)
    idle_index = headers.index("IDLE")

    refute_nil idle_index
    assert_equal "-", row.fetch(idle_index)
  end

  def test_truncate_repo_truncates_long_paths
    status = Harnex::Status.new([])
    result = status.send(:truncate_repo, "/very/long/path/to/some/deep/repo")
    assert_operator result.length, :<=, Harnex::Status::REPO_WIDTH
    assert result.start_with?("..")
  end

  private

  def create_git_repo
    dir = Dir.mktmpdir("harnex-status-repo")
    @created_dirs << dir
    system("git", "init", "-q", dir, out: File::NULL, err: File::NULL)
    dir
  end

  def test_status_labels_unreachable_live_api_as_degraded_registry_data
    write_registry("degraded")

    status = Harnex::Status.new(["--json", "--id", "degraded"])
    out, = capture_io { assert_equal 0, status.run }
    row = JSON.parse(out).first

    assert_equal "running", row["state"]
    assert_equal "registry", row["source"]
    assert_equal true, row["degraded"]
    assert_equal "unreachable", row["live_status"]
  end

  def test_status_id_reports_running_from_unpaired_start_record
    Dir.mktmpdir("harnex-status-start-record") do |repo|
      system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      child_pid = spawn("sleep", "30")
      Harnex::DispatchHistory.append(
        Harnex::DispatchHistory.path_for(repo),
        schema_version: 1, record_type: "dispatch_start", id: "cx-t-96",
        session_id: "sess-96", pid: child_pid, host: Harnex.host_info[:host],
        cli: "codex", description: "mid-run worker", started_at: Time.now.utc.iso8601,
        repo_root: repo, tier: nil, meta: {}, summary_out_path: nil,
        events_log_path: Harnex.events_log_path(repo, "cx-t-96")
      )

      status = Harnex::Status.new(["--json", "--id", "cx-t-96", "--repo", repo])
      out, = capture_io { assert_equal 0, status.run }
      row = JSON.parse(out).first

      assert_equal "running", row["state"]
      assert_equal "running", row["work_state"]
      assert_equal false, row["done"]
      assert_equal false, row["terminal"]
      assert_equal "dispatch_start", row["source"]
      assert_equal true, row["degraded"]
    ensure
      begin
        Process.kill("KILL", child_pid) if child_pid
        Process.waitpid(child_pid, Process::WNOHANG)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end

  def write_registry(id, description: nil, include_log_keys: false, log_mtime: nil, log_idle_s: nil, last_completed_at: nil)
    path = Harnex.registry_path(@repo_root, id)
    payload = {
      "id" => id,
      "cli" => "codex",
      "pid" => Process.pid,
      "host" => "127.0.0.1",
      "port" => 43_210 + @created_paths.length,
      "repo_root" => @repo_root,
      "started_at" => Time.now.iso8601
    }
    payload["description"] = description if description
    payload["last_completed_at"] = last_completed_at if last_completed_at
    if include_log_keys
      payload["log_mtime"] = log_mtime
      payload["log_idle_s"] = log_idle_s
    end
    Harnex.write_registry(path, payload)
    @created_paths << path
  end
end
