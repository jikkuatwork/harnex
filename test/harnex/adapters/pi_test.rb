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

  def test_build_returns_pi_adapter
    adapter = Harnex::Adapters.build("pi", ["--model", "anthropic/claude-sonnet-4-5"])
    assert_instance_of Harnex::Adapters::Pi, adapter
    assert_equal ["pi", "--mode", "rpc", "--model", "anthropic/claude-sonnet-4-5"], adapter.build_command
  end

  def test_known_adapters_include_pi
    assert_includes Harnex::Adapters.known, "pi"
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
