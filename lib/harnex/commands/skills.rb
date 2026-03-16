require "fileutils"

module Harnex
  class Skills
    SKILL_SOURCE = File.expand_path("../../../../skills/harnex", __FILE__)

    def self.usage
      <<~TEXT
        Usage: harnex skills install [--global]

        Subcommands:
          install     Install the harnex skill into the current repo

        Options:
          --global    Install to ~/.claude/skills and ~/.codex/skills
                      instead of the current repo

        Without --global, copies the skill to .claude/skills/harnex/
        in the current repo and symlinks .codex/skills/harnex to it.

        With --global, symlinks both ~/.claude/skills/harnex and
        ~/.codex/skills/harnex to the harnex source.
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      subcommand = @argv.shift
      case subcommand
      when "install"
        global = @argv.include?("--global")
        global ? install_global : install_local
      when "-h", "--help", nil
        puts self.class.usage
        0
      else
        warn("harnex skills: unknown subcommand #{subcommand.inspect}")
        puts self.class.usage
        1
      end
    end

    private

    def install_local
      repo_root = Harnex.resolve_repo_root(Dir.pwd)
      claude_dir = File.join(repo_root, ".claude", "skills", "harnex")
      codex_dir = File.join(repo_root, ".codex", "skills", "harnex")

      # Copy skill to .claude/skills/harnex/
      if Dir.exist?(claude_dir)
        warn("harnex skills: #{claude_dir} already exists, overwriting")
        FileUtils.rm_rf(claude_dir)
      end
      FileUtils.mkdir_p(File.dirname(claude_dir))
      FileUtils.cp_r(SKILL_SOURCE, claude_dir)
      puts "installed #{claude_dir}"

      # Symlink .codex/skills/harnex -> .claude/skills/harnex
      codex_parent = File.dirname(codex_dir)
      FileUtils.mkdir_p(codex_parent)
      FileUtils.rm_rf(codex_dir) if File.exist?(codex_dir) || File.symlink?(codex_dir)

      # Relative symlink so it works if the repo moves
      relative = relative_path(from: codex_parent, to: claude_dir)
      File.symlink(relative, codex_dir)
      puts "symlinked #{codex_dir} -> #{relative}"

      0
    end

    def install_global
      claude_dir = File.expand_path("~/.claude/skills/harnex")
      codex_dir = File.expand_path("~/.codex/skills/harnex")

      [claude_dir, codex_dir].each do |dir|
        parent = File.dirname(dir)
        FileUtils.mkdir_p(parent)
        FileUtils.rm_rf(dir) if File.exist?(dir) || File.symlink?(dir)
        File.symlink(SKILL_SOURCE, dir)
        puts "symlinked #{dir} -> #{SKILL_SOURCE}"
      end

      0
    end

    def relative_path(from:, to:)
      from_parts = File.expand_path(from).split("/")
      to_parts = File.expand_path(to).split("/")

      # Drop common prefix
      while from_parts.first == to_parts.first && !from_parts.empty?
        from_parts.shift
        to_parts.shift
      end

      ([".."] * from_parts.length + to_parts).join("/")
    end
  end
end
