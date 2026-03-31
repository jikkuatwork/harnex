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
      assert File.file?(File.join(home, ".claude", "skills", "dispatch", "SKILL.md"))
      assert File.file?(File.join(home, ".claude", "skills", "chain-implement", "SKILL.md"))
      refute File.symlink?(File.join(home, ".claude", "skills", "dispatch"))

      # ~/.codex/skills/ symlinked to ~/.claude/skills/
      codex_dispatch = File.join(home, ".codex", "skills", "dispatch")
      assert File.symlink?(codex_dispatch)
      assert_equal File.join(home, ".claude", "skills", "dispatch"),
                   File.readlink(codex_dispatch)
    end
  end

  def test_install_local_copies_to_repo
    in_tmp_repo do |dir|
      out, err = capture_io do
        assert_equal 0, Harnex::Skills.new(["install", "--local"]).run
      end

      assert_empty err
      assert File.file?(File.join(dir, ".claude", "skills", "dispatch", "SKILL.md"))
      assert File.file?(File.join(dir, ".claude", "skills", "chain-implement", "SKILL.md"))
      assert File.symlink?(File.join(dir, ".codex", "skills", "dispatch"))
      assert File.symlink?(File.join(dir, ".codex", "skills", "chain-implement"))
    end
  end

  def test_install_rejects_positional_arguments
    in_tmp_repo do
      _out, err = capture_io do
        assert_raises(RuntimeError) do
          Harnex::Skills.new(["install", "dispatch"]).run
        end
      end

      assert_match(/unexpected argument/, err)
    end
  end
end
