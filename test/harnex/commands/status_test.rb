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

  def test_status_id_filters_results
    write_registry("alpha")
    write_registry("beta")

    status = Harnex::Status.new(["--json", "--id", "beta"])
    out, = capture_io { assert_equal 0, status.run }
    data = JSON.parse(out)

    assert_equal 1, data.length
    assert_equal "beta", data.first["id"]
  end

  private

  def write_registry(id, description: nil)
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
    Harnex.write_registry(path, payload)
    @created_paths << path
  end
end
