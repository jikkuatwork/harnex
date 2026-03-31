require "fileutils"

module Harnex
  class Skills
    SKILLS_ROOT = File.expand_path("../../../../skills", __FILE__)
    INSTALL_SKILLS = %w[dispatch chain-implement].freeze

    def self.usage
      <<~TEXT
        Usage: harnex skills install [--local]

        Subcommands:
          install     Install bundled skills (globally by default)

        Options:
          --local     Install to the current repo instead of globally

        Installs: #{INSTALL_SKILLS.join(', ')}

        By default, copies each skill to ~/.claude/skills/<skill>/
        and symlinks ~/.codex/skills/<skill> to it.

        With --local, copies each skill to .claude/skills/<skill>/
        in the current repo and symlinks .codex/skills/<skill> to it.
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      subcommand = @argv.shift
      case subcommand
      when "install"
        skill_names, local, help = parse_install_args(@argv)
        if help
          puts self.class.usage
          return 0
        end

        skill_names.each do |skill_name|
          skill_source = resolve_skill_source(skill_name)
          unless skill_source
            return missing_skill(skill_name)
          end

          result = local ? install_local(skill_name, skill_source) : install_global(skill_name, skill_source)
          return result unless result == 0
        end
        0
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
      local = false
      help = false

      args.each do |arg|
        case arg
        when "--local"
          local = true
        when "-h", "--help"
          help = true
        when /\A-/
          raise "harnex skills: unknown option #{arg.inspect}"
        else
          warn("harnex skills install: unexpected argument #{arg.inspect}")
          raise "harnex skills install takes no positional arguments"
        end
      end

      [INSTALL_SKILLS, local, help]
    end

    def resolve_skill_source(skill_name)
      path = File.join(SKILLS_ROOT, skill_name)
      File.directory?(path) ? path : nil
    end

    def missing_skill(skill_name)
      warn("harnex skills: bundled skill #{skill_name.inspect} not found at #{SKILLS_ROOT}")
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

      # Copy skill to ~/.claude/skills/<skill>/
      if Dir.exist?(claude_dir)
        warn("harnex skills: #{claude_dir} already exists, overwriting")
        FileUtils.rm_rf(claude_dir)
      end
      FileUtils.mkdir_p(File.dirname(claude_dir))
      FileUtils.cp_r(skill_source, claude_dir)
      puts "installed #{claude_dir}"

      # Symlink ~/.codex/skills/<skill> -> ~/.claude/skills/<skill>
      codex_parent = File.dirname(codex_dir)
      FileUtils.mkdir_p(codex_parent)
      FileUtils.rm_rf(codex_dir) if File.exist?(codex_dir) || File.symlink?(codex_dir)
      File.symlink(claude_dir, codex_dir)
      puts "symlinked #{codex_dir} -> #{claude_dir}"

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
