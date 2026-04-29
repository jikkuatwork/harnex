require_relative "../../test_helper"

class StatusCommandTest < Minitest::Test
  def setup
    @repo_root = Dir.pwd
    @created_paths = []
  end

  def teardown
    @created_paths.each { |path| FileUtils.rm_f(path) }
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

  def write_registry(id, description: nil, include_log_keys: false, log_mtime: nil, log_idle_s: nil)
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
    if include_log_keys
      payload["log_mtime"] = log_mtime
      payload["log_idle_s"] = log_idle_s
    end
    Harnex.write_registry(path, payload)
    @created_paths << path
  end
end
