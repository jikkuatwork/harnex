require_relative "../../test_helper"
require "stringio"

class MCPCommandTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir("harnex-home")
    @old_home = ENV["HOME"]
    ENV["HOME"] = @home
  end

  def teardown
    ENV["HOME"] = @old_home
    FileUtils.rm_rf(@home)
  end

  def run_command(*argv)
    out = StringIO.new
    command = Harnex::MCPCommand.new(argv, out: out, err: StringIO.new)
    command.define_singleton_method(:which) { |_name| false } # no claude/pi CLIs in tests
    [command.send(:install_agent), out.string]
  end

  def test_installs_the_gpt_agent_once_and_never_replaces_one
    agent = File.join(@home, ".claude", "agents", "gpt.md")
    code, out = run_command("install")
    assert_equal 0, code
    assert_includes out, "installed the gpt agent"
    assert_equal File.read(Harnex::MCPCommand::AGENT_SOURCE), File.read(agent)

    File.write(agent, "my own gpt agent")
    _code, out = run_command("install")
    assert_includes out, "kept the existing gpt agent"
    assert_equal "my own gpt agent", File.read(agent)
  end

  def test_no_agent_and_dry_run
    agent = File.join(@home, ".claude", "agents", "gpt.md")
    run_command("install", "--no-agent")
    refute File.exist?(agent)
    _code, out = run_command("install", "--dry-run")
    assert_includes out, "would install the gpt agent"
    refute File.exist?(agent)
  end

  def test_shipped_agent_relays_only_through_harnex_tools
    text = File.read(Harnex::MCPCommand::AGENT_SOURCE)
    assert_includes text, "name: gpt"
    assert_match(/^tools: mcp__harnex__ask, mcp__harnex__delegate, mcp__harnex__reply, mcp__harnex__result$/, text)
    refute_match(/^tools:.*Bash/, text)
  end
end
