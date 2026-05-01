require_relative "../../test_helper"

require "rbconfig"

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

  def test_status_payload_includes_events_log_path
    session = build_session
    payload = session.status_payload(include_input_state: false)
    assert_equal Harnex.events_log_path(Dir.pwd, session.id), payload[:events_log_path]
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

  def test_events_log_records_started_and_exited_round_trip
    session = build_session
    session.send(:prepare_events_log)
    session.send(:emit_event, "started", pid: 12_345)
    session.instance_variable_set(:@exit_code, 0)
    session.send(:emit_exit_event)

    rows = File.readlines(session.events_log_path).map { |line| JSON.parse(line) }
    assert_equal %w[started exited], rows.map { |row| row["type"] }
    assert_equal [1, 2], rows.map { |row| row["seq"] }
    assert_equal 12_345, rows[0]["pid"]
    assert_equal 0, rows[1]["code"]
  ensure
    events_log = session.instance_variable_get(:@events_log)
    events_log&.close unless events_log&.closed?
  end

  def test_started_event_includes_meta_when_provided
    session = build_session(meta: { "issue" => "23", "predicted" => { "input_tokens" => [1, 2] } })
    session.send(:prepare_events_log)
    session.instance_variable_set(:@pid, 12_345)
    session.send(:emit_started_event)

    row = JSON.parse(File.readlines(session.events_log_path).last)
    assert_equal "started", row["type"]
    assert_equal 12_345, row["pid"]
    assert_equal({ "issue" => "23", "predicted" => { "input_tokens" => [1, 2] } }, row["meta"])
  ensure
    events_log = session.instance_variable_get(:@events_log)
    events_log&.close unless events_log&.closed?
  end

  def test_run_emits_usage_and_git_events_before_exited
    Dir.mktmpdir("harnex-session-git") do |repo|
      system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      File.write(File.join(repo, "README.md"), "one\n")
      system("git", "-C", repo, "add", "README.md", out: File::NULL, err: File::NULL)
      system("git", "-C", repo, "-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-q", "-m", "initial", out: File::NULL, err: File::NULL)

      code = <<~RUBY
        repo = ARGV.fetch(0)
        Dir.chdir(repo) do
          File.write("CHANGE.md", "two\\n")
          system("git", "add", "CHANGE.md", out: File::NULL, err: File::NULL)
          system("git", "-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-q", "-m", "session", out: File::NULL, err: File::NULL)
        end
        puts "Token usage: total=106,867 input=104,158 (+ 250,880 cached) output=2,709 (reasoning 870)"
        puts "To continue this session, run codex resume 019ddf05-0f03-7d70-904f-23db7f00640f"
      RUBY

      session = build_session(
        adapter: Harnex::Adapters::Codex.new,
        command: [RbConfig.ruby, "-e", code, repo],
        repo_root: repo
      )
      silence_session_stdout(session)

      assert_equal 0, session.run(validate_binary: false)

      rows = File.readlines(session.events_log_path).map { |line| JSON.parse(line) }
      assert_equal %w[started git usage git exited], rows.map { |row| row["type"] }

      git_start = rows[1]
      assert_equal "start", git_start["phase"]
      assert_match(/\A[0-9a-f]{40}\z/, git_start["sha"])
      refute_empty git_start["branch"]

      usage = rows[2]
      assert_equal 104_158, usage["input_tokens"]
      assert_equal 2_709, usage["output_tokens"]
      assert_equal 870, usage["reasoning_tokens"]
      assert_equal 250_880, usage["cached_tokens"]
      assert_equal 106_867, usage["total_tokens"]
      assert_equal "019ddf05-0f03-7d70-904f-23db7f00640f", usage["agent_session_id"]

      git_end = rows[3]
      assert_equal "end", git_end["phase"]
      assert_equal 1, git_end["loc_added"]
      assert_equal 0, git_end["loc_removed"]
      assert_equal 1, git_end["files_changed"]
      assert_equal 1, git_end["commits"]
      assert_equal 0, rows[4]["code"]
    end
  end

  def test_inject_via_adapter_emits_send_event_with_preview_fields
    session = build_session
    session.send(:prepare_events_log)

    session.adapter.define_singleton_method(:wait_for_sendable) do |_snapshot_fn, submit:, enter_only:, force:|
      ""
    end
    session.adapter.define_singleton_method(:build_send_payload) do |text:, submit:, enter_only:, screen_text:, force:|
      {
        steps: [{ text: text, newline: true }],
        input_state: { "state" => "prompt" },
        force: force
      }
    end
    session.define_singleton_method(:inject_sequence) do |_steps|
      { ok: true, bytes_written: 205, injected_count: 1, newline: true }
    end

    text = "x" * 205
    result = session.inject_via_adapter(text: text, submit: true, enter_only: false, force: true)
    row = JSON.parse(File.readlines(session.events_log_path).last)

    assert_equal "send", row["type"]
    assert_equal true, row["forced"]
    assert_equal true, row["msg_truncated"]
    assert_equal 201, row["msg"].length
    assert_equal "…", row["msg"][-1]
    assert_equal true, result[:force]
  ensure
    events_log = session.instance_variable_get(:@events_log)
    events_log&.close unless events_log&.closed?
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

  def build_session(command: ["ruby"], adapter: nil, repo_root: Dir.pwd, description: nil, meta: nil, inbox_ttl: Harnex::Inbox::DEFAULT_TTL)
    adapter ||= Harnex::Adapters::Generic.new(command.first.to_s)

    Harnex::Session.new(
      adapter: adapter,
      command: command,
      repo_root: repo_root,
      host: "127.0.0.1",
      id: "session-#{SecureRandom.hex(4)}",
      description: description,
      meta: meta,
      inbox_ttl: inbox_ttl
    )
  end

  def silence_session_stdout(session)
    session.define_singleton_method(:start_output_thread) do
      Thread.new do
        loop do
          chunk = instance_variable_get(:@reader).readpartial(4096)
          send(:record_output, chunk)
        rescue EOFError, Errno::EIO, IOError
          break
        end
      end
    end
  end
end
