require_relative "../../test_helper"

class SessionTest < Minitest::Test
  def test_validate_binary_raises_for_missing_binary
    session = build_session(command: ["missing-harnex-binary-#{$$}"])
    assert_raises(Harnex::BinaryNotFound) { session.validate_binary! }
  end

  def test_validate_binary_passes_for_existing_binary
    build_session(command: ["ruby"]).validate_binary!
  end

  def test_child_env_includes_description
    session = build_session(description: "implement auth module")
    env = session.send(:child_env)
    assert_equal "implement auth module", env["HARNEX_DESCRIPTION"]
  end

  def test_child_env_includes_spawner_pane_when_tmux_pane_set
    ENV["TMUX_PANE"] = "%42"
    session = build_session
    env = session.send(:child_env)
    assert_equal "%42", env["HARNEX_SPAWNER_PANE"]
  ensure
    ENV.delete("TMUX_PANE")
  end

  def test_child_env_omits_spawner_pane_when_tmux_pane_unset
    ENV.delete("TMUX_PANE")
    session = build_session
    env = session.send(:child_env)
    refute env.key?("HARNEX_SPAWNER_PANE")
  end

  def test_status_payload_includes_description
    session = build_session(description: "implement auth module")
    payload = session.status_payload(include_input_state: false)
    assert_equal "implement auth module", payload[:description]
  end

  def test_status_payload_includes_output_log_path
    session = build_session
    payload = session.status_payload(include_input_state: false)
    assert_equal Harnex.output_log_path(Dir.pwd, session.id), payload[:output_log_path]
  end

  def test_status_payload_sets_log_activity_fields_to_nil_when_log_missing
    session = build_session
    FileUtils.rm_f(session.output_log_path)

    payload = session.status_payload(include_input_state: false)

    assert_nil payload[:log_mtime]
    assert_nil payload[:log_idle_s]
  end

  def test_status_payload_reports_log_activity_and_later_output_advances_mtime
    session = build_session
    session.send(:prepare_output_log)
    session.send(:record_output, "first\n".b)

    stale = Time.now - 120
    File.utime(stale, stale, session.output_log_path)

    payload_before = session.status_payload(include_input_state: false)
    assert_kind_of String, payload_before[:log_mtime]
    assert_kind_of Integer, payload_before[:log_idle_s]
    mtime_before = Time.iso8601(payload_before[:log_mtime])

    session.send(:record_output, "second\n".b)
    payload_after = session.status_payload(include_input_state: false)
    assert_kind_of String, payload_after[:log_mtime]
    assert_kind_of Integer, payload_after[:log_idle_s]
    mtime_after = Time.iso8601(payload_after[:log_mtime])

    assert_operator mtime_after, :>, mtime_before
  ensure
    output_log = session.instance_variable_get(:@output_log)
    output_log&.close unless output_log&.closed?
  end

  def test_session_uses_configured_inbox_ttl
    session = build_session(inbox_ttl: 42.5)
    assert_in_delta 42.5, session.inbox.instance_variable_get(:@ttl), 0.0001
  end

  def test_record_output_writes_to_output_log
    session = build_session
    session.send(:prepare_output_log)
    session.send(:record_output, "hello\n".b)

    assert_equal "hello\n".b, File.binread(session.output_log_path)
  ensure
    output_log = session.instance_variable_get(:@output_log)
    output_log&.close unless output_log&.closed?
  end

  def test_prepare_output_log_appends_existing_transcript
    session = build_session
    File.binwrite(session.output_log_path, "old\n".b)

    session.send(:prepare_output_log)
    session.send(:record_output, "new\n".b)

    assert_equal "old\nnew\n".b, File.binread(session.output_log_path)
  ensure
    output_log = session.instance_variable_get(:@output_log)
    output_log&.close unless output_log&.closed?
  end

  def test_persist_registry_preserves_tmux_metadata
    session = build_session
    path = Harnex.registry_path(Dir.pwd, session.id)
    Harnex.write_registry(path, {
      "id" => session.id,
      "pid" => Process.pid,
      "repo_root" => Dir.pwd,
      "tmux_target" => "%91",
      "tmux_session" => "harnex",
      "tmux_window" => "cx-91"
    })

    session.send(:persist_registry)

    payload = JSON.parse(File.read(path))
    assert_equal "%91", payload["tmux_target"]
    assert_equal "harnex", payload["tmux_session"]
    assert_equal "cx-91", payload["tmux_window"]
  ensure
    FileUtils.rm_f(path) if path
  end

  def test_persist_exit_status_writes_zero_exit_code
    session = build_session
    session.instance_variable_set(:@exit_code, 0)
    session.send(:persist_exit_status)

    data = JSON.parse(File.read(Harnex.exit_status_path(Dir.pwd, session.id)))
    assert_equal 0, data["exit_code"]
    refute data.key?("signal")
  end

  def test_persist_exit_status_includes_signal_metadata
    session = build_session
    session.instance_variable_set(:@exit_code, 143)
    session.instance_variable_set(:@term_signal, 15)
    session.send(:persist_exit_status)

    data = JSON.parse(File.read(Harnex.exit_status_path(Dir.pwd, session.id)))
    assert_equal 143, data["exit_code"]
    assert_equal 15, data["signal"]
  end

  private

  def build_session(command: ["ruby"], description: nil, inbox_ttl: Harnex::Inbox::DEFAULT_TTL)
    adapter = Harnex::Adapters::Generic.new(command.first.to_s)

    Harnex::Session.new(
      adapter: adapter,
      command: command,
      repo_root: Dir.pwd,
      host: "127.0.0.1",
      id: "session-#{SecureRandom.hex(4)}",
      description: description,
      inbox_ttl: inbox_ttl
    )
  end
end
