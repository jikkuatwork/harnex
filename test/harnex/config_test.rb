require_relative "../test_helper"

class ConfigTest < Minitest::Test
  def test_load_repo_returns_empty_config_without_git_root
    original = Harnex::DispatchHistory.method(:find_git_root)
    Harnex::DispatchHistory.define_singleton_method(:find_git_root) { |_path| nil }

    config = Harnex::Config.load_repo("/tmp/harnex-config-nongit")

    assert_nil config.root
    assert_nil config.path
    refute config.present?
    assert_equal({}, config.data)
  ensure
    Harnex::DispatchHistory.define_singleton_method(:find_git_root, original) if original
  end

  def test_load_repo_returns_empty_config_when_file_is_absent
    with_git_repo do |repo|
      config = Harnex::Config.load_repo(repo)

      assert_equal repo, config.root
      assert_equal File.join(repo, ".harnex", "config.json"), config.path
      refute config.present?
      assert_equal({}, config.data)
    end
  end

  def test_load_repo_accepts_valid_phase_config
    with_git_repo do |repo|
      write_repo_config(repo, phase: { allowlist: ["implement", "code-review"], policy: "warn" })

      config = Harnex::Config.load_repo(File.join(repo, "nested"))

      assert config.present?
      assert_equal ["implement", "code-review"], config.phase.fetch("allowlist")
      assert_equal "warn", config.phase.fetch("policy")
    end
  end

  def test_load_repo_accepts_config_without_phase_section
    with_git_repo do |repo|
      write_repo_config(repo, other: { days: 14 })

      config = Harnex::Config.load_repo(repo)

      assert config.present?
      assert_nil config.phase
      assert_equal({ "days" => 14 }, config.data.fetch("other"))
    end
  end

  def test_retention_limits_default_and_env_overrides
    with_git_repo do |repo|
      write_repo_config(repo, retention: { events: { max_age_days: 30, max_bytes: 1234 } })

      config = Harnex::Config.load_repo(repo)
      limits = Harnex::Config.retention_limits(
        config: config,
        env: {
          "HARNEX_EVENTS_MAX_BYTES" => "4321",
          "HARNEX_OUTPUT_MAX_AGE_DAYS" => "7"
        }
      )

      assert_equal 30, limits.fetch("events").fetch("max_age_days")
      assert_equal 4321, limits.fetch("events").fetch("max_bytes")
      assert_equal 7, limits.fetch("output").fetch("max_age_days")
      assert_equal 1_073_741_824, limits.fetch("output").fetch("max_bytes")
    end
  end

  def test_retention_limits_reject_non_positive_config_and_env_values
    with_git_repo do |repo|
      write_repo_config(repo, retention: { events: { max_age_days: 0 } })

      error = assert_raises(Harnex::Config::ConfigError) { Harnex::Config.load_repo(repo) }
      assert_includes error.message, "$.retention.events.max_age_days"
    end

    with_git_repo do |repo|
      config = Harnex::Config.load_repo(repo)
      error = assert_raises(Harnex::Config::ConfigError) do
        Harnex::Config.retention_limits(config: config, env: { "HARNEX_OUTPUT_MAX_BYTES" => "0" })
      end
      assert_includes error.message, "HARNEX_OUTPUT_MAX_BYTES"
      assert_includes error.message, "positive integer"
    end
  end

  def test_load_repo_rejects_malformed_json_with_path
    with_git_repo do |repo|
      path = File.join(repo, ".harnex", "config.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{")

      error = assert_raises(Harnex::Config::ConfigError) { Harnex::Config.load_repo(repo) }
      assert_includes error.message, path
      assert_includes error.message, "malformed JSON"
    end
  end

  def test_load_repo_rejects_invalid_phase_shapes
    cases = [
      [{ phase: [] }, "$.phase must be an object"],
      [{ phase: { allowlist: "implement", policy: "warn" } }, "$.phase.allowlist must be an array"],
      [{ phase: { allowlist: ["implement", ""], policy: "warn" } }, "$.phase.allowlist[1] must be a non-empty string"],
      [{ phase: { allowlist: ["implement"], policy: "audit" } }, "$.phase.policy must be one of warn, reject"]
    ]

    cases.each do |payload, expected|
      with_git_repo do |repo|
        write_repo_config(repo, payload)

        error = assert_raises(Harnex::Config::ConfigError) { Harnex::Config.load_repo(repo) }
        assert_includes error.message, File.join(repo, ".harnex", "config.json")
        assert_includes error.message, expected
      end
    end
  end

  private

  def with_git_repo
    Dir.mktmpdir("harnex-config-repo") do |repo|
      assert system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      FileUtils.mkdir_p(File.join(repo, "nested"))
      yield repo
    end
  end

  def write_repo_config(repo, payload)
    path = File.join(repo, ".harnex", "config.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(payload))
    path
  end
end
