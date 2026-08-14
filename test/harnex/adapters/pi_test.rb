require_relative "../../test_helper"
require "json"

class PiAdapterTest < Minitest::Test
  def setup
    @adapter = Harnex::Adapters::Pi.new
  end

  def test_base_command_and_transport
    assert_equal ["pi", "--mode", "rpc"], @adapter.base_command
    assert_equal :stdio_jsonl_rpc, @adapter.transport
  end

  def test_startup_controls_become_pi_cli_flags
    @adapter.configure_startup(
      model: "anthropic/claude-sonnet-4-5",
      effort: "high"
    )

    assert_equal [
      "pi", "--mode", "rpc",
      "--model", "anthropic/claude-sonnet-4-5",
      "--thinking", "high"
    ], @adapter.build_command
  end

  def test_build_returns_pi_adapter
    adapter = Harnex::Adapters.build("pi", ["--model", "anthropic/claude-sonnet-4-5"])
    assert_instance_of Harnex::Adapters::Pi, adapter
    assert_equal ["pi", "--mode", "rpc", "--model", "anthropic/claude-sonnet-4-5"], adapter.build_command
  end

  def test_known_adapters_include_pi
    assert_includes Harnex::Adapters.known, "pi"
  end

  def test_runtime_requires_agent_settled_capable_pi
    @adapter.stub(:agent_version, "0.80.3") do
      error = assert_raises(RuntimeError) { @adapter.validate_runtime! }
      assert_includes error.message, "requires Pi >= 0.80.4"
    end

    @adapter.stub(:agent_version, "0.84.1") do
      assert_equal true, @adapter.validate_runtime!
    end
  end

  def test_describe_declares_current_settlement_contract
    description = @adapter.describe
    assert_equal "0.80.4", description.fetch(:minimum_version)
    assert_includes description.fetch(:events), "agent_settled"
    assert_includes description.fetch(:events), "summarization_retry_scheduled"
  end

  def test_build_command_strips_harnex_context_marker
    adapter = Harnex::Adapters::Pi.new([
      "--model", "anthropic/claude-sonnet-4-5",
      "[harnex session id=cx-i-44] implement task"
    ])

    assert_equal ["pi", "--mode", "rpc", "--model", "anthropic/claude-sonnet-4-5"], adapter.build_command
    assert_equal "[harnex session id=cx-i-44] implement task", adapter.initial_prompt
  end

  def test_dispatch_sends_prompt_command
    server_in, client_out = IO.pipe
    client_in, server_out = IO.pipe

    server = Thread.new do
      loop do
        line = server_in.gets
        break unless line

        command = JSON.parse(line)
        case command["type"]
        when "prompt"
          server_out.write(JSON.generate({
            "type" => "response",
            "id" => command["id"],
            "command" => "prompt",
            "success" => true
          }) + "\n")
          server_out.flush
          break
        end
      end
    rescue IOError, Errno::EPIPE
      nil
    end

    @adapter.start_rpc(read_io: client_in, write_io: client_out, pid: nil)
    @adapter.dispatch(prompt: "hello")

    state = @adapter.input_state
    assert_equal "busy", state[:state]
    assert_equal false, state[:input_ready]
  ensure
    @adapter.close rescue nil
    server&.join(1)
    [server_out, client_out, client_in, server_in].each { |io| io.close unless io.closed? rescue nil }
  end

  def test_dispatch_applies_model_and_effort_through_rpc_commands
    server_in, client_out = IO.pipe
    client_in, server_out = IO.pipe
    commands = []

    server = Thread.new do
      loop do
        line = server_in.gets
        break unless line

        command = JSON.parse(line)
        commands << command
        response = case command["type"]
                   when "get_state"
                     {
                       "type" => "response", "command" => "get_state", "success" => true,
                       "data" => {
                         "isStreaming" => false,
                         "thinkingLevel" => "high",
                         "model" => { "provider" => "anthropic", "id" => "claude-sonnet-4-5" },
                         "sessionId" => "pi-model-test"
                       }
                     }
                   when "set_model"
                     {
                       "type" => "response", "command" => "set_model", "success" => true,
                       "data" => { "provider" => command["provider"], "id" => command["modelId"] }
                     }
                   when "set_thinking_level"
                     { "type" => "response", "command" => "set_thinking_level", "success" => true }
                   when "prompt"
                     { "type" => "response", "command" => "prompt", "success" => true }
                   end
        next unless response

        response["id"] = command["id"] if command.key?("id")
        server_out.write(JSON.generate(response) + "\n")
        server_out.flush
        break if command["type"] == "prompt"
      end
    rescue IOError, Errno::EPIPE
      nil
    end

    @adapter.start_rpc(read_io: client_in, write_io: client_out, pid: nil)
    @adapter.dispatch(
      prompt: "hello",
      model: "anthropic/claude-sonnet-4-5",
      effort: "high"
    )

    types = commands.map { |command| command["type"] }
    assert_operator types.index("set_model"), :<, types.index("set_thinking_level")
    assert_operator types.index("set_thinking_level"), :<, types.index("prompt")
    model_command = commands.find { |command| command["type"] == "set_model" }
    assert_equal "anthropic", model_command["provider"]
    assert_equal "claude-sonnet-4-5", model_command["modelId"]
    prompt = commands.find { |command| command["type"] == "prompt" }
    assert_equal %w[id message type], prompt.keys.sort
  ensure
    @adapter.close rescue nil
    server&.join(1)
    [server_out, client_out, client_in, server_in].each { |io| io.close unless io.closed? rescue nil }
  end

  def test_dispatch_rejects_clamped_thinking_level
    @adapter.define_singleton_method(:request) do |payload, timeout: Harnex::Adapters::Pi::REQUEST_TIMEOUT_SECONDS|
      payload["type"] == "get_state" ? { "thinkingLevel" => "low" } : {}
    end

    error = assert_raises(ArgumentError) do
      @adapter.send(:apply_dispatch_overrides, model: nil, effort: "high")
    end
    assert_includes error.message, "effective level is \"low\""
  end

  def test_force_while_busy_maps_to_pi_steering_prompt
    @adapter.send(:handle_event, { "type" => "agent_start" })

    payload = @adapter.build_send_payload(
      text: "change direction",
      submit: true,
      enter_only: false,
      screen_text: nil,
      force: true
    )

    assert_equal "change direction", payload.dig(:dispatch, :prompt)
    assert_equal "steer", payload.dig(:dispatch, :streaming_behavior)
  end

  def test_stale_idle_state_response_does_not_override_event_proven_busy
    @adapter.send(:handle_event, { "type" => "agent_start" })
    @adapter.send(:absorb_state_data, { "isStreaming" => false, "isCompacting" => false })

    assert_equal "busy", @adapter.input_state.fetch(:state)
  end

  def test_agent_end_stays_busy_until_agent_settled
    @adapter.send(:handle_event, { "type" => "agent_start" })
    @adapter.send(:handle_event, { "type" => "agent_end", "willRetry" => false })
    assert_equal "busy", @adapter.input_state.fetch(:state)
    assert_nil @adapter.last_completed_at

    @adapter.send(:handle_event, { "type" => "agent_settled" })
    assert_equal "prompt", @adapter.input_state.fetch(:state)
    refute_nil @adapter.last_completed_at
  end

  def test_request_timeout_is_bounded
    server_in, client_out = IO.pipe
    client_in, server_out = IO.pipe
    @adapter.start_rpc(read_io: client_in, write_io: client_out, pid: nil)

    error = assert_raises(RuntimeError) do
      @adapter.send(:request, { "type" => "get_state" }, timeout: 0.02)
    end
    assert_includes error.message, "timed out"
  ensure
    @adapter.close rescue nil
    [server_out, client_out, client_in, server_in].each { |io| io.close unless io.closed? rescue nil }
  end

  def test_respond_extension_ui_cancel_writes_cancelled_response
    server_in, client_out = IO.pipe
    client_in, server_out = IO.pipe

    @adapter.start_rpc(read_io: client_in, write_io: client_out, pid: nil)
    assert_equal true, @adapter.respond_extension_ui_cancel(request_id: "req-1", method: "confirm")

    message = nil
    3.times do
      line = server_in.gets
      break unless line
      parsed = JSON.parse(line)
      next unless parsed["type"] == "extension_ui_response"

      message = parsed
      break
    end

    refute_nil message
    assert_equal "extension_ui_response", message["type"]
    assert_equal "req-1", message["id"]
    assert_equal true, message["cancelled"]
  ensure
    @adapter.close rescue nil
    [server_out, client_out, client_in, server_in].each { |io| io.close unless io.closed? rescue nil }
  end

  def test_collect_session_summary_uses_stats_and_model_provider
    server_in, client_out = IO.pipe
    client_in, server_out = IO.pipe

    server = Thread.new do
      loop do
        line = server_in.gets
        break unless line

        command = JSON.parse(line)
        case command["type"]
        when "get_state"
          response = {
            "type" => "response",
            "command" => "get_state",
            "success" => true,
            "data" => {
              "isStreaming" => false,
              "model" => { "provider" => "anthropic", "id" => "claude-sonnet-4-5" },
              "sessionId" => "pi-session-1"
            }
          }
          response["id"] = command["id"] if command.key?("id")
          server_out.write(JSON.generate(response) + "\n")
          server_out.flush
        when "get_session_stats"
          response = {
            "type" => "response",
            "command" => "get_session_stats",
            "success" => true,
            "data" => {
              "sessionId" => "pi-session-1",
              "toolCalls" => 7,
              "tokens" => {
                "input" => 100,
                "output" => 40,
                "cacheRead" => 60,
                "total" => 200
              },
              "cost" => 0.12,
              "contextUsage" => {
                "tokens" => 64_000,
                "contextWindow" => 200_000,
                "percent" => 32
              }
            }
          }
          response["id"] = command["id"] if command.key?("id")
          server_out.write(JSON.generate(response) + "\n")
          server_out.flush
        end
      end
    rescue IOError, Errno::EPIPE
      nil
    end

    @adapter.start_rpc(read_io: client_in, write_io: client_out, pid: nil)
    @adapter.request_session_stats_async

    deadline = Time.now + 1.0
    loop do
      summary = @adapter.collect_session_summary
      break if summary[:total_tokens] == 200
      raise "timed out waiting for stats" if Time.now > deadline

      sleep 0.01
    end

    summary = @adapter.collect_session_summary
    assert_equal 100, summary[:input_tokens]
    assert_equal 40, summary[:output_tokens]
    assert_equal 60, summary[:cached_tokens]
    assert_equal 200, summary[:total_tokens]
    assert_equal 7, summary[:tool_calls]
    assert_equal 0.12, summary[:cost_usd]
    assert_equal "pi-session-1", summary[:agent_session_id]
    assert_equal "claude-sonnet-4-5", summary[:model]
    assert_equal "anthropic", summary[:agent_provider]
    assert_equal "observed", summary.dig(:context, :status)
    assert_equal "pi_get_session_stats", summary.dig(:context, :source)
    assert_equal 64_000, summary.dig(:context, :terminal_tokens)
    assert_equal 200_000, summary.dig(:context, :window_tokens)
    assert_equal 32.0, summary.dig(:context, :terminal_percent)
  ensure
    @adapter.close rescue nil
    server&.join(1)
    [server_out, client_out, client_in, server_in].each { |io| io.close unless io.closed? rescue nil }
  end

  def test_context_usage_tracks_terminal_and_peak_across_stats_samples
    @adapter.send(:absorb_session_stats, {
      "contextUsage" => { "tokens" => 40_000, "contextWindow" => 200_000, "percent" => 20 }
    })
    @adapter.send(:absorb_session_stats, {
      "contextUsage" => { "tokens" => 118_000, "contextWindow" => 200_000, "percent" => 59 }
    })
    @adapter.send(:absorb_session_stats, {
      "contextUsage" => { "tokens" => 64_000, "contextWindow" => 200_000, "percent" => 32 }
    })

    context = @adapter.collect_session_summary.fetch(:context)
    assert_equal "observed", context.fetch(:status)
    assert_equal 64_000, context.fetch(:terminal_tokens)
    assert_equal 32.0, context.fetch(:terminal_percent)
    assert_equal 118_000, context.fetch(:peak_tokens)
    assert_equal 59.0, context.fetch(:peak_percent)
    assert_equal 3, context.fetch(:samples)
    assert_equal 0, context.fetch(:missing_samples)
    assert_equal "observed", context.fetch(:latest_sample_status)
  end

  def test_null_post_compaction_context_sample_preserves_valid_high_water
    @adapter.send(:absorb_session_stats, {
      "contextUsage" => { "tokens" => 118_000, "contextWindow" => 200_000, "percent" => 59 }
    })
    @adapter.send(:absorb_session_stats, {
      "contextUsage" => { "tokens" => nil, "contextWindow" => 200_000, "percent" => nil }
    })

    context = @adapter.collect_session_summary.fetch(:context)
    assert_equal "observed", context.fetch(:status)
    assert_equal 118_000, context.fetch(:terminal_tokens)
    assert_equal 118_000, context.fetch(:peak_tokens)
    assert_equal 59.0, context.fetch(:terminal_percent)
    assert_equal 59.0, context.fetch(:peak_percent)
    assert_equal 2, context.fetch(:samples)
    assert_equal 1, context.fetch(:missing_samples)
    assert_equal "missing", context.fetch(:latest_sample_status)
  end
end
