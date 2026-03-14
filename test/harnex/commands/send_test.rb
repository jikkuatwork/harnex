require_relative "../../test_helper"

class SenderRelayTest < Minitest::Test
  # Test the relay logic in Sender without needing a live session.
  # We instantiate Sender and call private methods via send().

  def with_env(overrides)
    saved = {}
    overrides.each do |k, v|
      saved[k] = ENV[k]
      ENV[k] = v
    end
    yield
  ensure
    overrides.each { |k, _| saved[k] ? ENV[k] = saved[k] : ENV.delete(k) }
  end

  # --- relay_enabled_for? ---

  def test_relay_disabled_when_no_session_context
    sender = Harnex::Sender.new([])
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
      sender = Harnex::Sender.new([])
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
      sender = Harnex::Sender.new([])
      registry = { "session_id" => "same-session" }
      refute sender.send(:relay_enabled_for?, registry)
    end
  end

  def test_relay_disabled_when_enter_only
    env = {
      "HARNEX_SESSION_ID" => "sender-session",
      "HARNEX_SESSION_CLI" => "codex",
      "HARNEX_ID" => "worker-1"
    }
    with_env(env) do
      sender = Harnex::Sender.new(["--enter"])
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
      sender = Harnex::Sender.new(["--relay"])
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
      sender = Harnex::Sender.new(["--no-relay"])
      sender.send(:parser).parse!(sender.instance_variable_get(:@argv))
      registry = { "session_id" => "different-session" }
      refute sender.send(:relay_enabled_for?, registry)
    end
  end

  # --- relay_text ---

  def test_relay_text_wraps_message
    env = {
      "HARNEX_SESSION_ID" => "sender-session",
      "HARNEX_SESSION_CLI" => "codex",
      "HARNEX_ID" => "worker-1"
    }
    with_env(env) do
      sender = Harnex::Sender.new([])
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
      sender = Harnex::Sender.new([])
      registry = { "session_id" => "target-session" }
      already_relayed = "[harnex relay from=claude id=main at=2026-01-01T00:00:00Z]\nhello"
      text = sender.send(:relay_text, already_relayed, registry)
      assert_equal already_relayed, text
    end
  end

  def test_relay_text_empty_passthrough
    sender = Harnex::Sender.new([])
    registry = { "session_id" => "target-session" }
    assert_equal "", sender.send(:relay_text, "", registry)
  end

  # --- --token flag (bug #1 fix) ---

  def test_token_flag_parsed
    sender = Harnex::Sender.new(["--port", "9999", "--token", "secret123", "--message", "hi"])
    sender.send(:parser).parse!(sender.instance_variable_get(:@argv))
    opts = sender.instance_variable_get(:@options)
    assert_equal "secret123", opts[:token]
    assert_equal 9999, opts[:port]
  end

  # --- resolve_text ---

  def test_resolve_text_returns_empty_for_enter_only
    sender = Harnex::Sender.new(["--enter"])
    sender.send(:parser).parse!(sender.instance_variable_get(:@argv))
    assert_equal "", sender.send(:resolve_text)
  end

  def test_resolve_text_uses_message_option
    sender = Harnex::Sender.new(["--message", "hello"])
    sender.send(:parser).parse!(sender.instance_variable_get(:@argv))
    assert_equal "hello", sender.send(:resolve_text)
  end

  def test_resolve_text_joins_positional_args
    sender = Harnex::Sender.new(["hello", "world"])
    sender.send(:parser).parse!(sender.instance_variable_get(:@argv))
    assert_equal "hello world", sender.send(:resolve_text)
  end
end
