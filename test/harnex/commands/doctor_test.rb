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

  def test_doctor_reports_retention_without_pruning
    reset_retention_dirs
    old = File.join(Harnex::STATE_DIR, "events", "old.jsonl")
    File.write(old, "old")

    doctor = Harnex::Doctor.new
    doctor.stub(:check_codex, { name: "codex", ok: true }) do
      out, = capture_io { assert_equal 0, doctor.run }
      payload = JSON.parse(out)

      assert_equal true, payload.fetch("ok")
      assert_equal 1, payload.dig("retention", "directories", "events", "count")
      assert File.exist?(old)
    end
  end

  def test_doctor_prune_dry_run_previews_without_mutation
    reset_retention_dirs
    old = old_retention_file("events", "old.jsonl")

    doctor = Harnex::Doctor.new(["--prune", "--dry-run"])
    doctor.stub(:check_codex, { name: "codex", ok: true }) do
      out, = capture_io { assert_equal 0, doctor.run }
      payload = JSON.parse(out)

      assert_equal true, payload.dig("retention", "dry_run")
      assert_equal 1, payload.dig("retention", "directories", "events", "deleted_count")
      assert File.exist?(old)
    end
  end

  def test_doctor_prune_applies_deletions
    reset_retention_dirs
    old = old_retention_file("output", "old.log")

    doctor = Harnex::Doctor.new(["--prune"])
    doctor.stub(:check_codex, { name: "codex", ok: true }) do
      out, = capture_io { assert_equal 0, doctor.run }
      payload = JSON.parse(out)

      assert_equal false, payload.dig("retention", "dry_run")
      assert_equal 1, payload.dig("retention", "directories", "output", "deleted_count")
      refute File.exist?(old)
    end
  end

  def test_doctor_rejects_dry_run_without_prune
    error = assert_raises(OptionParser::InvalidOption) { Harnex::Doctor.new(["--dry-run"]).run }
    assert_includes error.message, "--dry-run requires --prune"
  end

  def success_status
    Minitest::Mock.new.expect(:success?, true)
  end

  def reset_retention_dirs
    %w[events output].each do |name|
      FileUtils.rm_rf(File.join(Harnex::STATE_DIR, name))
      FileUtils.mkdir_p(File.join(Harnex::STATE_DIR, name))
    end
    FileUtils.rm_f(File.join(Harnex::STATE_DIR, "retention.json"))
  end

  def old_retention_file(kind, name)
    path = File.join(Harnex::STATE_DIR, kind, name)
    File.write(path, "old")
    old = Time.now - 90 * 86_400
    File.utime(old, old, path)
    path
  end
end
