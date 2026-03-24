require_relative "../../test_helper"

class SkillsCommandTest < Minitest::Test
  def in_tmp_repo
    Dir.mktmpdir("harnex-skills-test") do |dir|
      Dir.chdir(dir) { yield dir }
    end
  end

  def test_install_defaults_to_harnex_for_backwards_compatibility
    in_tmp_repo do |dir|
      out, err = capture_io do
        assert_equal 0, Harnex::Skills.new(["install"]).run
      end

      assert_empty err
      assert_match(/installed .*\/\.claude\/skills\/harnex/, out)
      assert File.file?(File.join(dir, ".claude", "skills", "harnex", "SKILL.md"))
      assert File.symlink?(File.join(dir, ".codex", "skills", "harnex"))
    end
  end

  def test_install_local_requested_skill
    in_tmp_repo do |dir|
      out, err = capture_io do
        assert_equal 0, Harnex::Skills.new(["install", "close"]).run
      end

      claude_skill = File.join(dir, ".claude", "skills", "close")
      codex_skill = File.join(dir, ".codex", "skills", "close")

      assert_empty err
      assert_match(/installed .*\/\.claude\/skills\/close/, out)
      assert_match(/symlinked .*\/\.codex\/skills\/close -> \.\.\/\.\.\/\.claude\/skills\/close/, out)
      assert File.file?(File.join(claude_skill, "SKILL.md"))
      assert File.symlink?(codex_skill)
      assert_equal "../../.claude/skills/close", File.readlink(codex_skill)
      assert_match(/^name: close$/, File.read(File.join(claude_skill, "SKILL.md")))
    end
  end

  def test_install_multiple_skills
    in_tmp_repo do |dir|
      out, err = capture_io do
        assert_equal 0, Harnex::Skills.new(["install", "dispatch", "chain-implement"]).run
      end

      assert_empty err
      assert File.file?(File.join(dir, ".claude", "skills", "dispatch", "SKILL.md"))
      assert File.file?(File.join(dir, ".claude", "skills", "chain-implement", "SKILL.md"))
      assert File.symlink?(File.join(dir, ".codex", "skills", "dispatch"))
      assert File.symlink?(File.join(dir, ".codex", "skills", "chain-implement"))
    end
  end

  def test_install_unknown_skill_returns_error_and_lists_available_skills
    in_tmp_repo do
      out, err = capture_io do
        assert_equal 1, Harnex::Skills.new(["install", "missing"]).run
      end

      assert_empty out
      assert_match(/unknown skill "missing"/, err)
      assert_match(/available skills: chain-implement, close, dispatch, harnex, open/, err)
    end
  end
end
