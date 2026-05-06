require_relative "../../test_helper"

require "rbconfig"
require "timeout"

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
        repo_root: repo,
        description: "dispatch telemetry",
        meta: {
          "model" => "gpt-5.3-codex",
          "effort" => "high",
          "issue" => "23",
          "plan" => "27",
          "predicted" => { "input_tokens" => [100, 200] }
        },
        summary_out: File.join(repo, "koder", "DISPATCH.jsonl")
      )
      silence_session_stdout(session)

      assert_equal 0, session.run(validate_binary: false)

      rows = File.readlines(session.events_log_path).map { |line| JSON.parse(line) }
      assert_equal %w[started git usage git summary exited], rows.map { |row| row["type"] }

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

      summary = rows[4]
      assert_equal File.join(repo, "koder", "DISPATCH.jsonl"), summary["path"]
      assert_equal "success", summary["exit"]
      assert_equal 0, rows[5]["code"]
      assert_equal "success", rows[5]["reason"]

      record = JSON.parse(File.read(summary["path"]).lines.last)
      assert_equal session.id, record.dig("meta", "id")
      assert_equal "dispatch telemetry", record.dig("meta", "description")
      assert_equal "harnex", record.dig("meta", "harness")
      assert_equal Harnex::VERSION, record.dig("meta", "harness_version")
      assert_equal "codex", record.dig("meta", "agent")
      assert_equal repo, record.dig("meta", "repo")
      assert_equal "23", record.dig("meta", "issue")
      assert_equal "27", record.dig("meta", "plan")
      assert_equal({ "input_tokens" => [100, 200] }, record["predicted"])
      assert_equal "gpt-5.3-codex", record.dig("actual", "model")
      assert_equal "high", record.dig("actual", "effort")
      assert_kind_of Integer, record.dig("actual", "duration_s")
      assert_equal 104_158, record.dig("actual", "input_tokens")
      assert_nil record.dig("actual", "cost_usd")
      assert_equal 1, record.dig("actual", "loc_added")
      assert_equal 1, record.dig("actual", "files_changed")
      assert_equal 1, record.dig("actual", "commits")
      assert_equal "success", record.dig("actual", "exit")
      assert_equal 0, record.dig("actual", "force_resumes")
      assert_nil record.dig("actual", "tests_run")
    end
  end

  def test_summary_record_uses_null_actuals_and_disconnected_exit_without_summary_marker
    Dir.mktmpdir("harnex-session-summary") do |repo|
      summary_path = File.join(repo, "DISPATCH.jsonl")
      session = build_session(
        command: [RbConfig.ruby, "-e", "puts 'no usage marker'"],
        repo_root: repo,
        summary_out: summary_path
      )
      silence_session_stdout(session)

      assert_equal 0, session.run(validate_binary: false)

      rows = File.readlines(session.events_log_path).map { |line| JSON.parse(line) }
      assert_equal %w[started usage summary exited], rows.map { |row| row["type"] }
      assert_equal "disconnected", rows[-2]["exit"]
      assert_equal "disconnected", rows[-1]["reason"]

      record = JSON.parse(File.read(summary_path).lines.last)
      assert_equal({}, record["predicted"])
      assert_nil record.dig("actual", "input_tokens")
      assert_nil record.dig("actual", "output_tokens")
      assert_nil record.dig("actual", "reasoning_tokens")
      assert_nil record.dig("actual", "cached_tokens")
      assert_nil record.dig("actual", "cost_usd")
      assert_equal "disconnected", record.dig("actual", "exit")
      assert_equal 1, record.dig("actual", "disconnections")
      assert_nil record.dig("actual", "tests_passed")
    end
  end

  def test_summary_event_has_nil_path_when_no_summary_path_resolves
    Dir.mktmpdir("harnex-session-summary") do |repo|
      session = build_session(
        command: [RbConfig.ruby, "-e", "exit 0"],
        repo_root: repo
      )
      silence_session_stdout(session)

      assert_equal 0, session.run(validate_binary: false)

      rows = File.readlines(session.events_log_path).map { |line| JSON.parse(line) }
      assert_equal %w[started usage summary exited], rows.map { |row| row["type"] }
      assert_nil rows[-2]["path"]
      refute File.exist?(File.join(repo, "koder", "DISPATCH.jsonl"))
    end
  end

  def test_summary_write_failure_warns_without_crashing_exit
    Dir.mktmpdir("harnex-session-summary") do |repo|
      session = build_session(
        command: [RbConfig.ruby, "-e", "exit 0"],
        repo_root: repo,
        summary_out: repo
      )
      silence_session_stdout(session)

      _out, err = capture_io { assert_equal 0, session.run(validate_binary: false) }

      assert_match(/failed to write dispatch summary/, err)
      rows = File.readlines(session.events_log_path).map { |line| JSON.parse(line) }
      assert_equal "summary", rows[-2]["type"]
      assert_equal repo, rows[-2]["path"]
      assert_equal "exited", rows[-1]["type"]
    end
  end

  def test_event_counters_tally_reserved_operational_events
    counters = Harnex::Session::EventCounters.new
    %w[resume log_idle compaction disconnection disconnect].each { |type| counters.record(type) }

    assert_equal(
      {
        stalls: 1,
        force_resumes: 1,
        disconnections: 2,
        compactions: 1
      },
      counters.snapshot
    )
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

  def test_jsonrpc_inject_stop_interrupts_then_terminates_subprocess
    adapter = Harnex::Adapters::CodexAppServer.new
    calls = Queue.new

    adapter.define_singleton_method(:interrupt) { |turn_id: nil| calls << [:interrupt, turn_id] }
    adapter.define_singleton_method(:terminate_subprocess) { calls << :terminate_subprocess }

    result = Harnex.stub(:allocate_port, 45_000) do
      session = build_session(command: adapter.build_command, adapter: adapter)
      session.inject_stop
    end

    assert_equal({ ok: true, signal: "interrupt_sent" }, result)
    observed = Timeout.timeout(2) { [calls.pop, calls.pop] }
    assert_equal [[:interrupt, nil], :terminate_subprocess], observed
  end

  def test_inject_stop_is_idempotent
    adapter = Harnex::Adapters::CodexAppServer.new
    calls = Queue.new

    adapter.define_singleton_method(:interrupt) { |turn_id: nil| calls << [:interrupt, turn_id] }
    adapter.define_singleton_method(:terminate_subprocess) { calls << :terminate_subprocess }

    session = Harnex.stub(:allocate_port, 45_001) do
      build_session(command: adapter.build_command, adapter: adapter)
    end

    assert_equal({ ok: true, signal: "interrupt_sent" }, session.inject_stop)
    assert_equal({ ok: true, signal: "already_requested" }, session.inject_stop)

    observed = Timeout.timeout(2) { [calls.pop, calls.pop] }
    assert_equal [[:interrupt, nil], :terminate_subprocess], observed
    refute wait_for_queue(calls, timeout: 0.1)
  end

  def test_auto_stop_jsonrpc_fires_after_first_task_complete
    adapter = Harnex::Adapters::CodexAppServer.new
    calls = Queue.new
    session = build_session(command: adapter.build_command, adapter: adapter, auto_stop: true)
    session.send(:prepare_events_log)
    session.define_singleton_method(:inject_stop) do |turn_id: nil|
      calls << [:stop, turn_id]
      { ok: true, signal: "test_stop" }
    end

    session.send(:handle_rpc_notification, {
      "method" => "turn/completed",
      "params" => { "turnId" => "trn-1", "status" => "completed" }
    })

    assert_equal [:stop, "trn-1"], Timeout.timeout(2) { calls.pop }

    session.send(:handle_rpc_notification, {
      "method" => "turn/completed",
      "params" => { "turnId" => "trn-2", "status" => "completed" }
    })

    refute wait_for_queue(calls, timeout: 0.1)
  ensure
    events_log = session&.instance_variable_get(:@events_log)
    events_log&.close unless events_log&.closed?
  end

  def test_auto_stop_pty_fires_after_busy_then_prompt
    adapter = Harnex::Adapters::Generic.new("ruby")
    calls = Queue.new
    session = build_session(adapter: adapter, auto_stop: true)
    session.send(:prepare_output_log)
    session.define_singleton_method(:inject_stop) do |turn_id: nil|
      calls << :stop
      { ok: true, signal: "test_stop" }
    end

    session.send(:arm_auto_stop_after_initial_context)
    session.send(:record_output, "working\n".b)
    refute wait_for_queue(calls, timeout: 0.1)

    session.send(:record_output, "> ".b)
    assert_equal :stop, Timeout.timeout(2) { calls.pop }

    session.send(:record_output, "\n> ".b)
    refute wait_for_queue(calls, timeout: 0.1)
  ensure
    output_log = session&.instance_variable_get(:@output_log)
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

  def build_session(command: ["ruby"], adapter: nil, repo_root: Dir.pwd, description: nil, meta: nil, summary_out: nil, inbox_ttl: Harnex::Inbox::DEFAULT_TTL, auto_stop: false)
    adapter ||= Harnex::Adapters::Generic.new(command.first.to_s)

    Harnex::Session.new(
      adapter: adapter,
      command: command,
      repo_root: repo_root,
      host: "127.0.0.1",
      id: "session-#{SecureRandom.hex(4)}",
      description: description,
      meta: meta,
      summary_out: summary_out,
      inbox_ttl: inbox_ttl,
      auto_stop: auto_stop
    )
  end

  def wait_for_queue(queue, timeout:)
    Timeout.timeout(timeout) { queue.pop }
  rescue Timeout::Error
    nil
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
