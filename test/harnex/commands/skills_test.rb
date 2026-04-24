require_relative "../../test_helper"

class SkillsCommandTest < Minitest::Test
  def in_tmp_repo
    Dir.mktmpdir("harnex-skills-test") do |dir|
      Dir.chdir(dir) { yield dir }
    end
  end

  def with_tmp_home
    Dir.mktmpdir("harnex-skills-home") do |home|
      original_home = ENV["HOME"]
      ENV["HOME"] = home
      begin
        yield home
      ensure
        ENV["HOME"] = original_home
      end
    end
  end

  def test_install_default_copies_to_home_directories
    with_tmp_home do |home|
      out, err = capture_io do
        assert_equal 0, Harnex::Skills.new(["install"]).run
      end

      assert_empty err

      # Skills copied to ~/.claude/skills/
      assert File.file?(File.join(home, ".claude", "skills", "harnex-dispatch", "SKILL.md"))
      assert File.file?(File.join(home, ".claude", "skills", "harnex-chain", "SKILL.md"))
      assert File.file?(File.join(home, ".claude", "skills", "harnex-buddy", "SKILL.md"))
      refute File.symlink?(File.join(home, ".claude", "skills", "harnex-dispatch"))

      # ~/.codex/skills/ symlinked to ~/.claude/skills/
      codex_dispatch = File.join(home, ".codex", "skills", "harnex-dispatch")
      assert File.symlink?(codex_dispatch)
      assert_equal File.join(home, ".claude", "skills", "harnex-dispatch"),
                   File.readlink(codex_dispatch)
    end
  end

  def test_install_local_copies_to_repo
    in_tmp_repo do |dir|
      out, err = capture_io do
        assert_equal 0, Harnex::Skills.new(["install", "--local"]).run
      end

      assert_empty err
      assert File.file?(File.join(dir, ".claude", "skills", "harnex-dispatch", "SKILL.md"))
      assert File.file?(File.join(dir, ".claude", "skills", "harnex-chain", "SKILL.md"))
      assert File.file?(File.join(dir, ".claude", "skills", "harnex-buddy", "SKILL.md"))
      assert File.symlink?(File.join(dir, ".codex", "skills", "harnex-dispatch"))
      assert File.symlink?(File.join(dir, ".codex", "skills", "harnex-chain"))
      assert File.symlink?(File.join(dir, ".codex", "skills", "harnex-buddy"))
    end
  end

  def test_install_removes_deprecated_skills
    with_tmp_home do |home|
      # Pre-install old-named skills
      %w[harnex dispatch chain-implement].each do |old_name|
        dir = File.join(home, ".claude", "skills", old_name)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "SKILL.md"), "old")
      end

      capture_io { Harnex::Skills.new(["install"]).run }

      # Old names removed
      refute File.exist?(File.join(home, ".claude", "skills", "harnex"))
      refute File.exist?(File.join(home, ".claude", "skills", "dispatch"))
      refute File.exist?(File.join(home, ".claude", "skills", "chain-implement"))

      # New names installed
      assert File.file?(File.join(home, ".claude", "skills", "harnex-dispatch", "SKILL.md"))
      assert File.file?(File.join(home, ".claude", "skills", "harnex-chain", "SKILL.md"))
    end
  end

  def test_install_harnex_alias_installs_dispatch_without_harnex_dir
    in_tmp_repo do |dir|
      out, err = capture_io do
        assert_equal 0, Harnex::Skills.new(["install", "harnex", "--local"]).run
      end

      assert_empty err
      assert_includes out, "harnex-dispatch"
      assert File.file?(File.join(dir, ".claude", "skills", "harnex-dispatch", "SKILL.md"))
      refute File.exist?(File.join(dir, ".claude", "skills", "harnex"))
      refute File.exist?(File.join(dir, ".codex", "skills", "harnex"))
      refute File.exist?(File.join(dir, ".claude", "skills", "harnex-chain"))
      refute File.exist?(File.join(dir, ".claude", "skills", "harnex-buddy"))
    end
  end

  def test_uninstall_global_removes_skills
    with_tmp_home do |home|
      # Install first
      capture_io { Harnex::Skills.new(["install"]).run }
      assert File.exist?(File.join(home, ".claude", "skills", "harnex-dispatch"))

      # Uninstall
      capture_io { Harnex::Skills.new(["uninstall"]).run }

      refute File.exist?(File.join(home, ".claude", "skills", "harnex-dispatch"))
      refute File.exist?(File.join(home, ".claude", "skills", "harnex-chain"))
      refute File.exist?(File.join(home, ".claude", "skills", "harnex-buddy"))
      refute File.exist?(File.join(home, ".codex", "skills", "harnex-dispatch"))
    end
  end

  def test_uninstall_local_removes_skills
    in_tmp_repo do |dir|
      capture_io { Harnex::Skills.new(["install", "--local"]).run }
      assert File.exist?(File.join(dir, ".claude", "skills", "harnex-dispatch"))

      capture_io { Harnex::Skills.new(["uninstall", "--local"]).run }

      refute File.exist?(File.join(dir, ".claude", "skills", "harnex-dispatch"))
      refute File.exist?(File.join(dir, ".claude", "skills", "harnex-chain"))
      refute File.exist?(File.join(dir, ".claude", "skills", "harnex-buddy"))
      refute File.exist?(File.join(dir, ".codex", "skills", "harnex-dispatch"))
    end
  end

  def test_uninstall_also_removes_deprecated_names
    with_tmp_home do |home|
      # Manually create old-named skills
      %w[harnex dispatch chain-implement].each do |old_name|
        dir = File.join(home, ".claude", "skills", old_name)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "SKILL.md"), "old")
      end

      capture_io { Harnex::Skills.new(["uninstall"]).run }

      refute File.exist?(File.join(home, ".claude", "skills", "harnex"))
      refute File.exist?(File.join(home, ".claude", "skills", "dispatch"))
      refute File.exist?(File.join(home, ".claude", "skills", "chain-implement"))
    end
  end
end
