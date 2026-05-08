require_relative "../../test_helper"
require "json"

class DoctorTest < Minitest::Test
  def test_help
    assert_output(/Usage: harnex doctor/) { Harnex::Doctor.new(["--help"]).run }
  end

  def test_parse_version_from_canonical_output
    doctor = Harnex::Doctor.new
    assert_equal Gem::Version.new("0.128.0"),
      doctor.send(:parse_version, "codex-cli 0.128.0\n")
  end

  def test_parse_version_returns_nil_for_garbage
    doctor = Harnex::Doctor.new
    assert_nil doctor.send(:parse_version, "no version here")
  end

  def test_min_version_constant
    assert_equal Gem::Version.new("0.128.0"), Harnex::Doctor::MIN_CODEX_VERSION
  end

  def test_sweep_payload_reports_active_orphan_and_stale_entries
    FileUtils.rm_rf(Harnex::SESSIONS_DIR)
    FileUtils.mkdir_p(Harnex::SESSIONS_DIR)
    output_dir = File.join(Harnex::STATE_DIR, "output")
    events_dir = File.join(Harnex::STATE_DIR, "events")
    FileUtils.mkdir_p(output_dir)
    FileUtils.mkdir_p(events_dir)

    repo = Dir.mktmpdir("harnex-doctor-repo")
    live_path = Harnex.registry_path(repo, "cx-live")
    stale_path = Harnex.registry_path(repo, "cx-stale")
    File.write(live_path, JSON.generate("id" => "cx-live", "repo_root" => repo, "pid" => Process.pid))
    File.write(stale_path, JSON.generate("id" => "cx-stale", "repo_root" => repo, "pid" => 999_999_999))

    stale_slug = Harnex.session_file_slug(repo, "cx-stale")
    File.write(File.join(output_dir, "#{stale_slug}.log"), "old output")
    File.write(File.join(events_dir, "#{stale_slug}.jsonl"), "{}\n")

    doctor = Harnex::Doctor.new(["--sweep"])
    doctor.stub(:check_codex, { name: "codex", ok: true }) do
      doctor.stub(:capture, ["cx-live\tcx-live\t#{Process.pid}\ncx-orphan\tcx-orphan\t123\n", success_status]) do
        out, status = capture_io { assert_equal 0, doctor.run }
        payload = JSON.parse(out)

        assert_equal true, payload["ok"]
        assert_equal ["cx-live"], payload.dig("sweep", "harnex_sessions").map { |row| row["id"] }
        assert_equal ["cx-orphan"], payload.dig("sweep", "orphan_tmux").map { |row| row["session"] }
        assert_equal ["cx-stale"], payload.dig("sweep", "stale_pid_files").map { |row| row["id"] }
        assert_empty status
      end
    end
  ensure
    FileUtils.rm_rf(repo) if repo
  end

  def success_status
    Minitest::Mock.new.expect(:success?, true)
  end
end
