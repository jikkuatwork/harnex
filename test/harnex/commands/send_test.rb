require_relative "../../test_helper"

class SenderRelayTest < Minitest::Test
  AcceptedResponse = Struct.new(:code, :body)

  def with_env(overrides)
    saved = {}
    overrides.each do |key, value|
      saved[key] = ENV[key]
      ENV[key] = value
    end
    yield
  ensure
    overrides.each { |key, _| saved[key] ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def test_send_requires_id
    sender = Harnex::Sender.new(["--message", "hello"])
    assert_raises(RuntimeError) { sender.run }
  end

  def test_relay_disabled_when_no_session_context
    sender = Harnex::Sender.new(["--id", "target"])
    registry = { "session_id" => "abc123" }
    refute sender.send(:relay_enabled_for?, registry)
  end

  def test_relay_enabled_for_cross_session
    env = {
      "HARNEX_SESSION_ID" => "sender-session",
      "HARNEX_SESSION_CLI" => "codex",
      "HARNEX_ID" => "worker-1"
    }
    with_env(env) do
      sender = Harnex::Sender.new(["--id", "target"])
      registry = { "session_id" => "different-session" }
      assert sender.send(:relay_enabled_for?, registry)
    end
  end

  def test_relay_disabled_for_same_session
    env = {
      "HARNEX_SESSION_ID" => "same-session",
      "HARNEX_SESSION_CLI" => "codex",
      "HARNEX_ID" => "worker-1"
    }
    with_env(env) do
      sender = Harnex::Sender.new(["--id", "target"])
      registry = { "session_id" => "same-session" }
      refute sender.send(:relay_enabled_for?, registry)
    end
  end

  def test_relay_disabled_when_submit_only
    env = {
      "HARNEX_SESSION_ID" => "sender-session",
      "HARNEX_SESSION_CLI" => "codex",
      "HARNEX_ID" => "worker-1"
    }
    with_env(env) do
      sender = Harnex::Sender.new(["--id", "target", "--submit-only"])
      sender.send(:parser).parse!(sender.instance_variable_get(:@argv))
      registry = { "session_id" => "different-session" }
      refute sender.send(:relay_enabled_for?, registry)
    end
  end

  def test_relay_forced_with_flag
    env = {
      "HARNEX_SESSION_ID" => "same-session",
      "HARNEX_SESSION_CLI" => "codex",
      "HARNEX_ID" => "worker-1"
    }
    with_env(env) do
      sender = Harnex::Sender.new(["--id", "target", "--relay"])
      sender.send(:parser).parse!(sender.instance_variable_get(:@argv))
      registry = { "session_id" => "same-session" }
      assert sender.send(:relay_enabled_for?, registry)
    end
  end

  def test_relay_suppressed_with_no_relay_flag
    env = {
      "HARNEX_SESSION_ID" => "sender-session",
      "HARNEX_SESSION_CLI" => "codex",
      "HARNEX_ID" => "worker-1"
    }
    with_env(env) do
      sender = Harnex::Sender.new(["--id", "target", "--no-relay"])
      sender.send(:parser).parse!(sender.instance_variable_get(:@argv))
      registry = { "session_id" => "different-session" }
      refute sender.send(:relay_enabled_for?, registry)
    end
  end

  def test_relay_text_wraps_message
    env = {
      "HARNEX_SESSION_ID" => "sender-session",
      "HARNEX_SESSION_CLI" => "codex",
      "HARNEX_ID" => "worker-1"
    }
    with_env(env) do
      sender = Harnex::Sender.new(["--id", "target"])
      registry = { "session_id" => "target-session" }
      text = sender.send(:relay_text, "hello world", registry)
      assert text.start_with?("[harnex relay from=codex id=worker-1")
      assert text.include?("hello world")
    end
  end

  def test_relay_text_does_not_double_wrap
    env = {
      "HARNEX_SESSION_ID" => "sender-session",
      "HARNEX_SESSION_CLI" => "codex",
      "HARNEX_ID" => "worker-1"
    }
    with_env(env) do
      sender = Harnex::Sender.new(["--id", "target"])
      registry = { "session_id" => "target-session" }
      already_relayed = "[harnex relay from=claude id=main at=2026-01-01T00:00:00Z]\nhello"
      text = sender.send(:relay_text, already_relayed, registry)
      assert_equal already_relayed, text
    end
  end

  def test_relay_text_empty_passthrough
    sender = Harnex::Sender.new(["--id", "target"])
    registry = { "session_id" => "target-session" }
    assert_equal "", sender.send(:relay_text, "", registry)
  end

  def test_token_flag_parsed
    sender = Harnex::Sender.new(["--id", "target", "--port", "9999", "--token", "secret123", "--message", "hi"])
    sender.send(:parser).parse!(sender.instance_variable_get(:@argv))
    opts = sender.instance_variable_get(:@options)
    assert_equal "secret123", opts[:token]
    assert_equal 9999, opts[:port]
  end

  def test_resolve_text_returns_empty_for_submit_only
    sender = Harnex::Sender.new(["--id", "target", "--submit-only"])
    sender.send(:parser).parse!(sender.instance_variable_get(:@argv))
    assert_equal "", sender.send(:resolve_text)
  end

  def test_resolve_text_uses_message_option
    sender = Harnex::Sender.new(["--id", "target", "--message", "hello"])
    sender.send(:parser).parse!(sender.instance_variable_get(:@argv))
    assert_equal "hello", sender.send(:resolve_text)
  end

  def test_resolve_text_accepts_negative_message
    sender = Harnex::Sender.new(["--id", "target", "--message", "-1"])
    sender.send(:parser).parse!(sender.instance_variable_get(:@argv))
    assert_equal "-1", sender.send(:resolve_text)
  end

  def test_resolve_text_joins_positional_args
    sender = Harnex::Sender.new(["--id", "target", "hello", "world"])
    sender.send(:parser).parse!(sender.instance_variable_get(:@argv))
    assert_equal "hello world", sender.send(:resolve_text)
  end

  def test_validate_modes_rejects_submit_only_with_message_text
    sender = Harnex::Sender.new(["--id", "target", "--submit-only", "--message", "hello"])
    assert_raises(RuntimeError) { sender.run }
  end

  def test_run_uses_one_deadline_across_lookup_request_and_delivery
    sender = Harnex::Sender.new(["--id", "target", "--message", "hello", "--timeout", "5"])
    registry = { "host" => "127.0.0.1", "port" => 40123, "session_id" => "peer-session" }
    response = AcceptedResponse.new("202", JSON.generate("message_id" => "msg-1"))
    deadlines = []

    sender.define_singleton_method(:wait_for_registry) do |_repo_root, deadline:|
      deadlines << deadline
      registry
    end
    sender.define_singleton_method(:with_http_retry) do |deadline:, &block|
      deadlines << deadline
      response
    end
    sender.define_singleton_method(:poll_delivery) do |_registry, _message_id, deadline:|
      deadlines << deadline
      { "status" => "delivered", "ok" => true }
    end

    out, = capture_io { assert_equal 0, sender.run }
    data = JSON.parse(out)
    assert_equal "delivered", data["status"]
    assert_equal 3, deadlines.length
    assert_equal 1, deadlines.uniq.length
  end
end
