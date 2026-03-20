require "fileutils"

module Harnex
  class Skills
    SKILLS_ROOT = File.expand_path("../../../../skills", __FILE__)
    DEFAULT_SKILL = "harnex"

    def self.usage
      available = bundled_skill_names
      skill_list = available.empty? ? "(none found)" : available.join(", ")

      <<~TEXT
        Usage: harnex skills install [SKILL] [--global]

        Subcommands:
          install     Install a bundled skill into the current repo

        Options:
          --global    Install to ~/.claude/skills and ~/.codex/skills
                      instead of the current repo

        Skill defaults to #{DEFAULT_SKILL.inspect} for backwards compatibility.
        Available bundled skills: #{skill_list}

        Without --global, copies the skill to .claude/skills/<skill>/
        in the current repo and symlinks .codex/skills/<skill> to it.

        With --global, symlinks both ~/.claude/skills/<skill> and
        ~/.codex/skills/<skill> to the bundled source.
      TEXT
    end

    def self.bundled_skill_names
      Dir.glob(File.join(SKILLS_ROOT, "*", "SKILL.md"))
        .map { |path| File.basename(File.dirname(path)) }
        .sort
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      subcommand = @argv.shift
      case subcommand
      when "install"
        skill_name, global, help = parse_install_args(@argv)
        if help
          puts self.class.usage
          return 0
        end

        skill_source = resolve_skill_source(skill_name)
        return missing_skill(skill_name) unless skill_source

        global ? install_global(skill_name, skill_source) : install_local(skill_name, skill_source)
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

    def parse_install_args(args)
      skill_name = nil
      global = false
      help = false

      args.each do |arg|
        case arg
        when "--global"
          global = true
        when "-h", "--help"
          help = true
        when /\A-/
          raise "harnex skills: unknown option #{arg.inspect}"
        else
          raise "harnex skills: too many arguments" if skill_name

          skill_name = arg
        end
      end

      [skill_name || DEFAULT_SKILL, global, help]
    end

    def resolve_skill_source(skill_name)
      return nil unless self.class.bundled_skill_names.include?(skill_name)

      File.join(SKILLS_ROOT, skill_name)
    end

    def missing_skill(skill_name)
      warn("harnex skills: unknown skill #{skill_name.inspect}")
      available = self.class.bundled_skill_names
      warn("available skills: #{available.join(', ')}") unless available.empty?
      1
    end

    def install_local(skill_name, skill_source)
      repo_root = Harnex.resolve_repo_root(Dir.pwd)
      claude_dir = File.join(repo_root, ".claude", "skills", skill_name)
      codex_dir = File.join(repo_root, ".codex", "skills", skill_name)

      # Copy skill to .claude/skills/<skill>/
      if Dir.exist?(claude_dir)
        warn("harnex skills: #{claude_dir} already exists, overwriting")
        FileUtils.rm_rf(claude_dir)
      end
      FileUtils.mkdir_p(File.dirname(claude_dir))
      FileUtils.cp_r(skill_source, claude_dir)
      puts "installed #{claude_dir}"

      # Symlink .codex/skills/<skill> -> .claude/skills/<skill>
      codex_parent = File.dirname(codex_dir)
      FileUtils.mkdir_p(codex_parent)
      FileUtils.rm_rf(codex_dir) if File.exist?(codex_dir) || File.symlink?(codex_dir)

      # Relative symlink so it works if the repo moves
      relative = relative_path(from: codex_parent, to: claude_dir)
      File.symlink(relative, codex_dir)
      puts "symlinked #{codex_dir} -> #{relative}"

      0
    end

    def install_global(skill_name, skill_source)
      claude_dir = File.expand_path("~/.claude/skills/#{skill_name}")
      codex_dir = File.expand_path("~/.codex/skills/#{skill_name}")

      [claude_dir, codex_dir].each do |dir|
        parent = File.dirname(dir)
        FileUtils.mkdir_p(parent)
        FileUtils.rm_rf(dir) if File.exist?(dir) || File.symlink?(dir)
        File.symlink(skill_source, dir)
        puts "symlinked #{dir} -> #{skill_source}"
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
