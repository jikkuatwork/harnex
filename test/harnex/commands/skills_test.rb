require_relative "../../test_helper"

class SkillsCommandTest < Minitest::Test
  def in_tmp_repo
    Dir.mktmpdir("harnex-skills-test") do |dir|
      Dir.chdir(dir) { yield dir }
    end
  end

  def test_install_installs_dispatch_and_chain_implement
    in_tmp_repo do |dir|
      out, err = capture_io do
        assert_equal 0, Harnex::Skills.new(["install"]).run
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
