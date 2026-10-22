require_relative "../test_helper"
require "stringio"

class MCPServerTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("harnex-mcp")
    @argv_log = File.join(@tmp, "argv.json")
    script = File.join(@tmp, "fake-harnex")
    # Logs argv, optionally sleeps (FAKE_SLEEP), prints a canned reply.
    File.write(script, <<~RUBY)
      require "json"
      File.write(#{@argv_log.inspect}, ARGV.to_json)
      sleep ARGV.include?("slow") ? 0.6 : 0
      if ARGV.include?("bad")
        warn "harnex delegate: unknown flag --bad"
        exit 2
      end
      puts "reply text\\n\\n── lane: done"
      exit 0
    RUBY
    @command = [Gem.ruby, script]
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def serve(*messages, interval: 15)
    input = StringIO.new(messages.map { |m| JSON.generate(m) }.join("\n") + "\n")
    output = StringIO.new
    Harnex::MCP::Server.new(input: input, output: output, harnex_command: @command, progress_interval: interval).run
    output.string.lines.map { |line| JSON.parse(line) }
  end

  def call(id, name, arguments, meta: nil)
    params = { "name" => name, "arguments" => arguments }
    params["_meta"] = meta if meta
    { "jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => params }
  end

  def argv
    JSON.parse(File.read(@argv_log))
  end

  def test_initialize_and_list_tools
    replies = serve({ "jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => { "protocolVersion" => "2025-06-18" } },
                    { "jsonrpc" => "2.0", "method" => "notifications/initialized" },
                    { "jsonrpc" => "2.0", "id" => 2, "method" => "tools/list" },
                    { "jsonrpc" => "2.0", "id" => 3, "method" => "nope" })
    init = replies.find { |r| r["id"] == 1 }["result"]
    assert_equal "2025-06-18", init["protocolVersion"]
    assert_equal "harnex", init.dig("serverInfo", "name")
    assert_includes init["instructions"], "self-contained"
    tools = replies.find { |r| r["id"] == 2 }.dig("result", "tools")
    assert_equal %w[ask delegate result reply land discard lanes], tools.map { |t| t["name"] }
    assert(tools.all? { |t| t["inputSchema"]["type"] == "object" && !t["description"].empty? })
    assert_equal(-32_601, replies.find { |r| r["id"] == 3 }.dig("error", "code"))
  end

  def test_delegate_maps_arguments_to_the_cli_and_returns_its_text
    replies = serve(call(1, "delegate", { "task" => "Add word count", "worktree" => "wc", "model" => "foundry-zyt/gpt-6-luna",
                                          "wait" => false, "wait_minutes" => 2 }))
    result = replies.first["result"]
    assert_equal false, result["isError"]
    assert_includes result.dig("content", 0, "text"), "reply text"
    assert_equal ["delegate", "--timeout", "120", "--worktree", "wc", "--model", "foundry-zyt/gpt-6-luna", "--no-wait", "--", "Add word count"], argv
  end

  def test_reply_result_land_and_ask_arguments
    serve(call(1, "reply", { "name" => "wc", "message" => "--also this" }))
    assert_equal ["reply", "--timeout", "1500", "wc", "--", "--also this"], argv
    serve(call(2, "result", { "names" => %w[a b] }))
    assert_equal ["result", "--timeout", "1500", "a", "b"], argv
    serve(call(3, "land", { "names" => %w[a b] }))
    assert_equal %w[land a b], argv
    serve(call(4, "ask", { "question" => "Why?", "fallback_model" => "m2" }))
    assert_equal ["ask", "--timeout", "1500"], argv.first(3)
    assert_match(/\Api-ask-\h{4}\z/, argv[argv.index("--id") + 1], "named up front so progress can follow it")
    assert_equal ["--fallback-model", "m2", "--", "Why?"], argv.last(4)
  end

  def test_progress_notifications_while_the_call_runs
    replies = serve(call(7, "delegate", { "task" => "slow" }, meta: { "progressToken" => "tok" }), interval: 0.15)
    progress = replies.select { |r| r["method"] == "notifications/progress" }
    refute_empty progress
    assert(progress.all? { |p| p.dig("params", "progressToken") == "tok" })
    assert_match(/working/, progress.first.dig("params", "message"))
    assert_equal 7, replies.last["id"]
  end

  def test_usage_errors_are_tool_errors_with_the_message
    replies = serve(call(1, "delegate", { "task" => "bad" }), call(2, "reply", { "name" => "x" }))
    first = replies.find { |r| r["id"] == 1 }["result"]
    assert_equal true, first["isError"]
    assert_includes first.dig("content", 0, "text"), "unknown flag --bad"
    second = replies.find { |r| r["id"] == 2 }["result"]
    assert_equal true, second["isError"]
    assert_includes second.dig("content", 0, "text"), "message is required"
  end

  def test_cancel_stops_waiting
    reader, writer = IO.pipe
    output = StringIO.new
    server = Thread.new do
      Harnex::MCP::Server.new(input: reader, output: output, harnex_command: @command, progress_interval: 0.05).run
    end
    writer.puts JSON.generate(call(9, "delegate", { "task" => "slow" }))
    sleep 0.2
    writer.puts JSON.generate("jsonrpc" => "2.0", "method" => "notifications/cancelled", "params" => { "requestId" => 9 })
    writer.close
    server.join(5)
    reply = output.string.lines.map { |l| JSON.parse(l) }.find { |r| r["id"] == 9 }
    assert_includes reply.dig("result", "content", 0, "text"), "cancelled"
  end
end
