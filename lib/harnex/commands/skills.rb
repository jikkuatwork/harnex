require "fileutils"

module Harnex
  class Skills
    SKILLS_ROOT = File.expand_path("../../../../skills", __FILE__)
    INSTALL_SKILLS = %w[harnex-dispatch harnex-chain harnex-buddy].freeze
    DEPRECATED_SKILLS = %w[harnex dispatch chain-implement].freeze
    SKILL_ALIASES = {
      "harnex" => "harnex-dispatch",
      "dispatch" => "harnex-dispatch",
      "chain-implement" => "harnex-chain"
    }.freeze

    def self.usage
      <<~TEXT
        Usage: harnex skills <subcommand> [SKILL...] [--local]

        Subcommands:
          install     Install bundled skills (globally by default; optional skill names)
          uninstall   Remove installed skills (globally by default)

        Options:
          --local     Target the current repo instead of global ~/.claude/

        Installs: #{INSTALL_SKILLS.join(', ')}
        Aliases: harnex|dispatch -> harnex-dispatch, chain-implement -> harnex-chain

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
        local, help, requested_skills = parse_args(@argv, allow_positional: true)
        return (puts self.class.usage; 0) if help

        remove_deprecated(local)
        install_skills = requested_skills.empty? ? INSTALL_SKILLS : canonical_skill_names(requested_skills)

        install_skills.each do |skill_name|
          skill_source = resolve_skill_source(skill_name)
          unless skill_source
            return missing_skill(skill_name)
          end

          result = local ? install_local(skill_name, skill_source) : install_global(skill_name, skill_source)
          return result unless result == 0
        end
        0
      when "uninstall"
        local, help, = parse_args(@argv)
        return (puts self.class.usage; 0) if help

        (INSTALL_SKILLS + DEPRECATED_SKILLS).each do |skill_name|
          local ? uninstall_local(skill_name) : uninstall_global(skill_name)
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

    def parse_args(args, allow_positional: false)
      local = false
      help = false
      positional = []

      args.each do |arg|
        case arg
        when "--local"
          local = true
        when "-h", "--help"
          help = true
        when /\A-/
          raise "harnex skills: unknown option #{arg.inspect}"
        else
          if allow_positional
            positional << arg
          else
            warn("harnex skills: unexpected argument #{arg.inspect}")
            raise "harnex skills takes no positional arguments"
          end
        end
      end

      [local, help, positional]
    end

    def resolve_skill_source(skill_name)
      path = File.join(SKILLS_ROOT, skill_name)
      File.directory?(path) ? path : nil
    end

    def missing_skill(skill_name)
      warn("harnex skills: bundled skill #{skill_name.inspect} not found at #{SKILLS_ROOT}")
      1
    end

    def remove_deprecated(local)
      DEPRECATED_SKILLS.each do |skill_name|
        local ? uninstall_local(skill_name) : uninstall_global(skill_name)
      end
    end

    def canonical_skill_names(skill_names)
      skill_names.map { |name| canonical_skill_name(name) }.uniq
    end

    def canonical_skill_name(skill_name)
      SKILL_ALIASES.fetch(skill_name, skill_name)
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

    def uninstall_local(skill_name)
      repo_root = Harnex.resolve_repo_root(Dir.pwd)
      claude_dir = File.join(repo_root, ".claude", "skills", skill_name)
      codex_dir = File.join(repo_root, ".codex", "skills", skill_name)

      removed = false
      if File.exist?(codex_dir) || File.symlink?(codex_dir)
        FileUtils.rm_rf(codex_dir)
        removed = true
      end
      if File.exist?(claude_dir) || File.symlink?(claude_dir)
        FileUtils.rm_rf(claude_dir)
        removed = true
      end
      puts "removed #{skill_name}" if removed
    end

    def uninstall_global(skill_name)
      claude_dir = File.expand_path("~/.claude/skills/#{skill_name}")
      codex_dir = File.expand_path("~/.codex/skills/#{skill_name}")

      removed = false
      if File.exist?(codex_dir) || File.symlink?(codex_dir)
        FileUtils.rm_rf(codex_dir)
        removed = true
      end
      if File.exist?(claude_dir) || File.symlink?(claude_dir)
        FileUtils.rm_rf(claude_dir)
        removed = true
      end
      puts "removed #{skill_name}" if removed
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
