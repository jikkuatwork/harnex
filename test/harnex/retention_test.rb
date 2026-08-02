require_relative "../test_helper"
require "json"

class RetentionTest < Minitest::Test
  def setup
    reset_state_dirs
  end

  def test_prune_deletes_files_older_than_age_and_keeps_current_path
    now = Time.utc(2026, 8, 3, 12, 0, 0)
    old = state_file("events", "old.jsonl", bytes: 5, mtime: now - 90 * 86_400)
    fresh = state_file("events", "fresh.jsonl", bytes: 5, mtime: now - 2 * 86_400)
    current = state_file("events", "current.jsonl", bytes: 5, mtime: now - 90 * 86_400)

    report = Harnex::Retention.prune(
      repo_root: Dir.pwd,
      current_paths: [current],
      env: env("HARNEX_EVENTS_MAX_AGE_DAYS" => "45"),
      force: true,
      now: now
    )

    refute File.exist?(old)
    assert File.exist?(fresh)
    assert File.exist?(current)
    assert_equal 1, report.fetch(:directories).fetch(:events).fetch(:deleted_count)
  end

  def test_prune_deletes_oldest_unprotected_files_until_size_cap
    now = Time.utc(2026, 8, 3, 12, 0, 0)
    oldest = state_file("output", "a.log", bytes: 6, mtime: now - 30)
    middle = state_file("output", "b.log", bytes: 6, mtime: now - 20)
    newest = state_file("output", "c.log", bytes: 6, mtime: now - 10)

    report = Harnex::Retention.prune(
      repo_root: Dir.pwd,
      env: env("HARNEX_OUTPUT_MAX_BYTES" => "10"),
      force: true,
      now: now
    )

    refute File.exist?(oldest)
    refute File.exist?(middle)
    assert File.exist?(newest)
    assert_equal 2, report.fetch(:directories).fetch(:output).fetch(:deleted_count)
    assert_equal 6, report.fetch(:directories).fetch(:output).fetch(:after_bytes)
  end

  def test_protected_bytes_may_leave_directory_over_cap
    now = Time.utc(2026, 8, 3, 12, 0, 0)
    protected = state_file("events", "protected.jsonl", bytes: 20, mtime: now - 90)
    candidate = state_file("events", "candidate.jsonl", bytes: 3, mtime: now - 80)

    report = Harnex::Retention.prune(
      repo_root: Dir.pwd,
      current_paths: [protected],
      env: env("HARNEX_EVENTS_MAX_BYTES" => "10"),
      force: true,
      now: now
    )

    assert File.exist?(protected)
    refute File.exist?(candidate)
    stats = report.fetch(:directories).fetch(:events)
    assert_equal true, stats.fetch(:over_cap)
    assert_equal 20, stats.fetch(:protected_bytes)
    assert_equal 20, stats.fetch(:after_bytes)
  end

  def test_prune_protects_live_registry_and_uncompleted_start_rows
    now = Time.utc(2026, 8, 3, 12, 0, 0)
    Dir.mktmpdir("harnex-retention-repo") do |repo|
      assert system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      registry_events = Harnex.events_log_path(repo, "cx-registry")
      registry_output = Harnex.output_log_path(repo, "cx-registry")
      started_events = Harnex.events_log_path(repo, "cx-started")
      started_output = Harnex.output_log_path(repo, "cx-started")
      stale_events = state_file("events", "stale.jsonl", bytes: 4, mtime: now - 90 * 86_400)

      [registry_events, registry_output, started_events, started_output].each do |path|
        File.write(path, "old")
        File.utime(now - 90 * 86_400, now - 90 * 86_400, path)
      end

      File.write(
        Harnex.registry_path(repo, "cx-registry"),
        JSON.generate(
          "id" => "cx-registry",
          "repo_root" => repo,
          "pid" => Process.pid,
          "events_log_path" => registry_events,
          "output_log_path" => registry_output
        )
      )
      Harnex::DispatchHistory.append(
        Harnex::DispatchHistory.path_for(repo),
        {
          "schema_version" => 2,
          "record_type" => "dispatch_start",
          "id" => "cx-started",
          "session_id" => "s1",
          "pid" => Process.pid,
          "host" => Harnex.host_info.fetch(:host),
          "repo_root" => repo,
          "events_log_path" => started_events
        }
      )
      File.open(Harnex::DispatchHistory.path_for(repo), "a") { |file| file.write("not json\n") }

      Harnex::Retention.prune(
        repo_root: repo,
        env: env(
          "HARNEX_EVENTS_MAX_AGE_DAYS" => "45",
          "HARNEX_OUTPUT_MAX_AGE_DAYS" => "45"
        ),
        force: true,
        now: now
      )

      assert File.exist?(registry_events)
      assert File.exist?(registry_output)
      assert File.exist?(started_events)
      assert File.exist?(started_output)
      refute File.exist?(stale_events)
    end
  end

  def test_dry_run_reports_deletions_without_mutation
    now = Time.utc(2026, 8, 3, 12, 0, 0)
    old = state_file("events", "old.jsonl", bytes: 5, mtime: now - 90 * 86_400)

    report = Harnex::Retention.prune(
      repo_root: Dir.pwd,
      dry_run: true,
      force: true,
      now: now
    )

    assert File.exist?(old)
    assert_equal true, report.fetch(:dry_run)
    assert_equal 1, report.fetch(:directories).fetch(:events).fetch(:deleted_count)
  end

  def test_scope_safety_skips_nested_directories_and_symlinks
    now = Time.utc(2026, 8, 3, 12, 0, 0)
    nested_dir = File.join(Harnex::STATE_DIR, "events", "nested")
    FileUtils.mkdir_p(nested_dir)
    nested_file = File.join(nested_dir, "old.jsonl")
    File.write(nested_file, "old")
    outside = File.join(Harnex::STATE_DIR, "outside.jsonl")
    File.write(outside, "outside")
    symlink = File.join(Harnex::STATE_DIR, "events", "link.jsonl")
    File.symlink(outside, symlink) if symlink_supported?

    Harnex::Retention.prune(
      repo_root: Dir.pwd,
      env: env("HARNEX_EVENTS_MAX_AGE_DAYS" => "1"),
      force: true,
      now: now
    )

    assert File.exist?(nested_file)
    assert File.exist?(outside)
    assert File.symlink?(symlink) if File.exist?(symlink) || File.symlink?(symlink)
  end

  def test_session_runs_automatic_prune_before_log_open
    calls = []
    session = Harnex::Session.allocate
    session.instance_variable_set(:@repo_root, Dir.pwd)
    session.instance_variable_set(:@output_log_path, File.join(Harnex::STATE_DIR, "output", "current.log"))
    session.instance_variable_set(:@events_log_path, File.join(Harnex::STATE_DIR, "events", "current.jsonl"))

    Harnex::Retention.stub(:auto_prune, ->(**kwargs) { calls << kwargs; { skipped: false } }) do
      session.__send__(:prune_retained_logs)
    end

    assert_equal 1, calls.length
    assert_includes calls.first.fetch(:current_paths), session.output_log_path
    assert_includes calls.first.fetch(:current_paths), session.events_log_path
  end

  private

  def reset_state_dirs
    %w[events output sessions].each do |name|
      FileUtils.rm_rf(File.join(Harnex::STATE_DIR, name))
      FileUtils.mkdir_p(File.join(Harnex::STATE_DIR, name))
    end
    %w[dispatch.jsonl retention.json retention.lock].each do |name|
      FileUtils.rm_f(File.join(Harnex::STATE_DIR, name))
    end
  end

  def state_file(kind, name, bytes:, mtime:)
    path = File.join(Harnex::STATE_DIR, kind, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "x" * bytes)
    File.utime(mtime, mtime, path)
    path
  end

  def env(overrides = {})
    overrides
  end

  def symlink_supported?
    probe = File.join(Harnex::STATE_DIR, "symlink-probe")
    target = File.join(Harnex::STATE_DIR, "symlink-target")
    File.write(target, "x")
    File.symlink(target, probe)
    true
  rescue NotImplementedError, SystemCallError
    false
  ensure
    FileUtils.rm_f(probe) if probe
    FileUtils.rm_f(target) if target
  end
end
