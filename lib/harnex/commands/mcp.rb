module Harnex
  # `harnex mcp` (#87): serve the lane verbs over MCP stdio, or register that
  # server with Claude Code (user scope) and Pi (~/.pi/agent/mcp.json).
  class MCPCommand
    SERVER_NAME = "harnex".freeze
    PI_TIMEOUT_SECONDS = 7200
    AGENT_SOURCE = File.expand_path("../../../agents/gpt.md", __dir__).freeze

    def self.agent_path
      File.expand_path("~/.claude/agents/gpt.md")
    end

    def self.usage
      <<~TEXT
        Usage: harnex mcp                  Serve MCP over stdio (what MCP clients run)
               harnex mcp install [--claude] [--pi] [--no-agent] [--dry-run]
               harnex mcp uninstall [--claude] [--pi]
               harnex mcp status

        Exposes ask, delegate, result, reply, land, discard and lanes as native tools.
        install registers the server for Claude Code (`claude mcp add --scope user`)
        and Pi (#{pi_config_path}, exposure direct). With neither flag it does both
        (each only when that CLI is installed). For Claude Code it also installs the
        `gpt` subagent at ~/.claude/agents/gpt.md unless one exists (--no-agent skips it).
        Restart running sessions afterwards.
      TEXT
    end

    # Where the agent-facing integrations stand (doctor reports this; it
    # reads config files only, so it never starts a client).
    def self.integrations
      claude = begin
        JSON.parse(File.read(File.expand_path("~/.claude.json"))).dig("mcpServers", SERVER_NAME)
      rescue StandardError
        nil
      end
      pi = begin
        JSON.parse(File.read(pi_config_path)).dig("mcpServers", SERVER_NAME)
      rescue StandardError
        nil
      end
      result = { claude_mcp: !claude.nil?, pi_mcp: !pi.nil?,
                 gpt_agent: File.exist?(agent_path) }
      result[:hint] = "run `harnex mcp install` for native tools in Claude Code and Pi" unless claude && pi
      result
    end

    def self.pi_config_path
      dir = ENV["PI_AGENT_DIR"] || ENV["PI_CODING_AGENT_DIR"] || File.expand_path("~/.pi/agent")
      File.join(dir, "mcp.json")
    end

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
    end

    def run
      action = @argv.first.to_s.start_with?("-") || @argv.empty? ? "serve" : @argv.shift
      if @argv.include?("-h") || @argv.include?("--help") || action == "help"
        @out.puts self.class.usage
        return 0
      end

      case action
      when "serve" then MCP::Server.new.run
      when "install" then install
      when "uninstall" then uninstall
      when "status" then status
      else
        raise OptionParser::InvalidArgument, "harnex mcp: unknown action #{action.inspect}; see harnex mcp --help"
      end
    end

    private

    def targets
      chosen = %w[claude pi].select { |name| @argv.include?("--#{name}") }
      chosen.empty? ? %w[claude pi] : chosen
    end

    def dry_run?
      @argv.include?("--dry-run")
    end

    # The RubyGems wrapper next to this Ruby runs the newest installed harnex
    # without depending on a version-manager shim or the client's cwd.
    def server_command
      wrapper = File.join(Gem.bindir, "harnex")
      File.executable?(wrapper) ? wrapper : "harnex"
    end

    def install
      targets.map { |target| send("install_#{target}") }.max
    end

    def uninstall
      targets.map { |target| send("uninstall_#{target}") }.max
    end

    def install_claude
      return skip("claude", "the claude CLI is not on PATH") unless which("claude")

      command = ["claude", "mcp", "add", "--transport", "stdio", "--scope", "user", SERVER_NAME, "--", server_command, "mcp"]
      if dry_run?
        say("claude", "would run: #{command.join(' ')}")
        return install_agent
      end

      Open3.capture3("claude", "mcp", "remove", SERVER_NAME, "--scope", "user")
      out, status = Open3.capture2e(*command)
      unless status.success?
        @err.puts("harnex mcp: claude mcp add failed: #{out.strip}")
        return 1
      end

      say("claude", "registered (user scope): #{server_command} mcp")
      install_agent
    end

    # The `gpt` subagent relays a brief to a worker through these tools. A
    # user's own agent of that name is never replaced.
    def install_agent
      return 0 if @argv.include?("--no-agent")

      path = self.class.agent_path
      return say("claude", "kept the existing gpt agent at #{path}") if File.exist?(path) || File.symlink?(path)
      return say("claude", "would install the gpt agent at #{path}") if dry_run?

      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.cp(AGENT_SOURCE, path)
      say("claude", "installed the gpt agent at #{path} (Agent subagent_type \"gpt\")")
    end

    def uninstall_claude
      return skip("claude", "the claude CLI is not on PATH") unless which("claude")

      out, status = Open3.capture2e("claude", "mcp", "remove", SERVER_NAME, "--scope", "user")
      say("claude", status.success? ? "removed" : "not registered (#{out.strip.lines.last.to_s.strip})")
      path = self.class.agent_path
      if File.file?(path) && !File.symlink?(path) && File.read(path) == File.read(AGENT_SOURCE)
        FileUtils.rm_f(path)
        say("claude", "removed the gpt agent harnex installed")
      end
      0
    end

    def install_pi
      path = self.class.pi_config_path
      return skip("pi", "#{File.dirname(path)} does not exist") unless File.directory?(File.dirname(path))

      config = read_json(path)
      config["mcpServers"] ||= {}
      config["mcpServers"][SERVER_NAME] = {
        "command" => server_command, "args" => ["mcp"], "exposure" => "direct", "timeout" => PI_TIMEOUT_SECONDS,
        "description" => "Hand work to Pi workers (GPT models): ask, delegate, result, reply, land, discard, lanes"
      }
      return say("pi", "would write #{path}: #{JSON.generate(config['mcpServers'][SERVER_NAME])}") if dry_run?

      Harnex.atomic_write_json(path, config)
      say("pi", "registered in #{path} (exposure direct, timeout #{PI_TIMEOUT_SECONDS}s)")
    end

    def uninstall_pi
      path = self.class.pi_config_path
      config = read_json(path)
      return say("pi", "not registered") unless config.dig("mcpServers", SERVER_NAME)

      config["mcpServers"].delete(SERVER_NAME)
      Harnex.atomic_write_json(path, config)
      say("pi", "removed from #{path}")
    end

    def status
      claude = if which("claude")
                 out, ok = Open3.capture2e("claude", "mcp", "get", SERVER_NAME)
                 ok.success? ? "registered: #{out.lines.grep(/Command|Args|Scope/i).map(&:strip).join('; ')}" : "not registered"
               else
                 "claude CLI not found"
               end
      pi = read_json(self.class.pi_config_path).dig("mcpServers", SERVER_NAME)
      @out.puts "claude: #{claude}"
      @out.puts "pi: #{pi ? "registered: #{pi['command']} #{Array(pi['args']).join(' ')} (exposure #{pi['exposure'] || 'codemode'})" : 'not registered'}"
      0
    end

    def read_json(path)
      JSON.parse(File.read(path))
    rescue Errno::ENOENT
      {}
    end

    def which(name)
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
    end

    def say(target, text)
      @out.puts "#{target}: #{text}"
      0
    end

    def skip(target, reason)
      @out.puts "#{target}: skipped (#{reason})"
      0
    end
  end
end
