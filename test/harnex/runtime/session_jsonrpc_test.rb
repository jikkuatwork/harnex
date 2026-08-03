require_relative "../../test_helper"
require_relative "../../support/codex_response_fixtures"
require "json"

class SessionJsonrpcTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("harnex-jsonrpc-test")
    # A real repo root so the canonical dispatch stream lands under @tmp.
    system("git", "init", "-q", @tmp, out: File::NULL, err: File::NULL)
    @adapter = Harnex::Adapters::CodexAppServer.new
    @session = Harnex::Session.new(
      adapter: @adapter,
      command: ["codex", "app-server"],
      repo_root: @tmp,
      host: "127.0.0.1",
      id: "test-jsonrpc"
    )
    @session.send(:prepare_output_log)
    @session.send(:prepare_events_log)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def fanout(method, params = {})
    @session.send(:handle_rpc_notification, { "method" => method, "params" => params })
  end

  def events
    File.readlines(@session.events_log_path).map { |l| JSON.parse(l) }
  end

  def output
    File.binread(@session.output_log_path)
  end

  def wait_for(timeout: 1.0)
    deadline = Time.now + timeout
    until yield
      return false if Time.now > deadline
      sleep 0.01
    end
    true
  end

  def start_session_with_stubbed_rpc(adapter:, session:, turn_requests:)
    server_in, client_out = IO.pipe
    client_in, server_out = IO.pipe
    original_start = adapter.method(:start_rpc)

    adapter.define_singleton_method(:start_rpc) do |env: nil, cwd: nil|
      original_start.call(env: env, cwd: cwd, read_io: client_in, write_io: client_out, pid: nil)
    end

    server = Thread.new do
      loop do
        readable = IO.select([server_in], nil, nil, 2.0)
        break unless readable

        line = server_in.gets
        break unless line

        req = JSON.parse(line)
        next unless req["id"]

        case req["method"]
        when "initialize"
          server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: {} }) + "\n")
        when "thread/start"
          server_out.write(JSON.generate({
            jsonrpc: "2.0", id: req["id"],
            result: Fixtures::Codex.thread_start_response(id: "thr-session")
          }) + "\n")
        when "turn/start"
          turn_requests << req
          server_out.write(JSON.generate({
            jsonrpc: "2.0", id: req["id"],
            result: Fixtures::Codex.turn_start_response(id: "trn-session")
          }) + "\n")
          server_out.write(JSON.generate({
            jsonrpc: "2.0",
            method: "turn/completed",
            params: Fixtures::Codex.turn_completed_notification(
              thread_id: "thr-session", turn_id: "trn-session", status: "completed"
            )
          }) + "\n")
        else
          server_out.write(JSON.generate({
            jsonrpc: "2.0",
            id: req["id"],
            error: { code: -32601, message: "unexpected #{req['method']}" }
          }) + "\n")
        end
        server_out.flush
      end
    rescue IOError, Errno::EPIPE
      nil
    end

    runner = Thread.new { session.run(validate_binary: false) }

    [runner, server, server_in, client_out, client_in, server_out]
  end

  def close_stubbed_rpc(handles)
    runner, server, server_in, client_out, client_in, server_out = handles
    [server_out, client_out, client_in, server_in].each do |io|
      io.close unless io.closed?
    rescue StandardError
      nil
    end
    reap_thread(runner)
    reap_thread(server)
  end

  def build_jsonrpc_session(adapter, id:)
    Harnex::Session.new(
      adapter: adapter,
      command: adapter.build_command,
      repo_root: @tmp,
      host: "127.0.0.1",
      id: id
    )
  end

  def dispatch_stream_path
    Harnex::DispatchHistory.path_for(@tmp)
  end

  def test_turn_completed_emits_task_complete_event
    fanout("thread/started", Fixtures::Codex.thread_started_notification(thread_id: "thr-a"))
    fanout("turn/started", Fixtures::Codex.turn_started_notification(thread_id: "thr-a", turn_id: "trn-a"))
    fanout("turn/completed",
      Fixtures::Codex.turn_completed_notification(thread_id: "thr-a", turn_id: "trn-a", status: "completed"))

    types = events.map { |e| e["type"] }
    assert_includes types, "turn_started"
    assert_includes types, "task_complete"

    completed = events.find { |e| e["type"] == "task_complete" }
    assert_equal "trn-a", completed["turnId"]
    assert_equal "completed", completed["status"]
  end

  def test_auto_stop_rejects_acknowledgment_only_turn_without_parsing_prose
    @session.instance_variable_set(:@auto_stop, true)
    stops = Queue.new
    @session.define_singleton_method(:inject_stop) do |turn_id: nil, interrupt: true|
      stops << [turn_id, interrupt]
      { ok: true, signal: "test" }
    end

    fanout("item/completed", Fixtures::Codex.item_completed_agent_message(
      text: "Got it—I will execute the task now."
    ))
    fanout("turn/completed",
      Fixtures::Codex.turn_completed_notification(thread_id: "thr-ack", turn_id: "trn-ack"))

    assert_equal [nil, false], Timeout.timeout(2) { stops.pop }
    failed = events.find { |event| event["type"] == "task_failed" }
    assert_equal "completed_no_activity", failed.fetch("status")
    assert_equal "completed_no_activity", failed.fetch("outcome_class")
    assert_match(/without command\/tool execution/, failed.fetch("message"))
    refute events.any? { |event| event["type"] == "task_complete" }
  end

  def test_initial_context_without_auto_stop_still_rejects_no_activity_completion
    adapter = Harnex::Adapters::CodexAppServer.new(["[harnex session id=context-gate] execute task"])
    session = Harnex::Session.new(
      adapter: adapter,
      command: adapter.build_command,
      repo_root: @tmp,
      host: "127.0.0.1",
      id: "context-gate"
    )
    session.send(:prepare_output_log)
    session.send(:prepare_events_log)

    session.send(:handle_rpc_notification, {
      "method" => "turn/completed",
      "params" => Fixtures::Codex.turn_completed_notification(thread_id: "thr-context", turn_id: "trn-context")
    })

    rows = File.readlines(session.events_log_path).map { |line| JSON.parse(line) }
    failed = rows.find { |event| event["type"] == "task_failed" }
    assert_equal "completed_no_activity", failed.fetch("outcome_class")
    refute session.task_complete?
    assert session.task_failed?
    session.instance_variable_set(:@exit_code, 0)
    session.send(:normalize_work_acceptance_exit_code!)
    assert_equal 1, session.exit_code
  ensure
    events_log = session&.instance_variable_get(:@events_log)
    events_log&.close unless events_log&.closed?
    output_log = session&.instance_variable_get(:@output_log)
    output_log&.close unless output_log&.closed?
  end

  def test_auto_stop_accepts_structured_command_activity_regardless_of_final_prose
    @session.instance_variable_set(:@auto_stop, true)
    @session.define_singleton_method(:inject_stop) do |turn_id: nil, interrupt: true|
      { ok: true, signal: "test" }
    end

    fanout("item/completed", {
      "item" => {
        "id" => "cmd-1",
        "type" => "commandExecution",
        "command" => "ruby -c lib/harnex/runtime/session.rb",
        "status" => "completed",
        "exitCode" => 0
      }
    })
    fanout("item/completed", Fixtures::Codex.item_completed_agent_message(text: "Acknowledged."))
    fanout("turn/completed",
      Fixtures::Codex.turn_completed_notification(thread_id: "thr-work", turn_id: "trn-work"))

    completed = events.find { |event| event["type"] == "task_complete" }
    assert_equal "completed_with_proof", completed.fetch("outcome_class")
    assert_equal "accepted", completed.fetch("artifact_report_status")
    assert_equal @session.artifact_report_path, completed.fetch("artifact_report_path")
    receipt = Harnex::ArtifactReport.validate(@session.artifact_report_path, final: true)
    assert receipt.ok
    assert_equal "ruby -c lib/harnex/runtime/session.rb", receipt.report.dig("observed", "commands", 0, "cmd")
    assert_equal 0, receipt.report.dig("observed", "commands", 0, "exit_code")
    assert @session.task_complete?
    refute @session.task_failed?
  end

  def test_harness_generates_no_change_receipt_and_attaches_review_claims
    system("git", "init", "-q", @tmp, out: File::NULL, err: File::NULL)
    File.write(File.join(@tmp, "README.md"), "receipt test\n")
    system("git", "-C", @tmp, "add", "README.md", out: File::NULL, err: File::NULL)
    system(
      "git", "-C", @tmp,
      "-c", "user.email=test@example.com", "-c", "user.name=Test",
      "commit", "-q", "-m", "initial",
      out: File::NULL, err: File::NULL
    )
    session = Harnex::Session.new(
      adapter: Harnex::Adapters::CodexAppServer.new,
      command: ["codex", "app-server"],
      repo_root: @tmp,
      host: "127.0.0.1",
      id: "observed-no-change",
      require_artifact_report: true
    )
    session.send(:prepare_output_log)
    session.send(:prepare_events_log)
    session.send(:emit_git_start_event)
    File.write(session.artifact_claims_path, JSON.generate(
      claims: {
        summary: "Review completed without repository changes.",
        verdict: "changes_requested",
        findings: { P1: 0, P2: 1, P3: 0 }
      }
    ))
    session.send(:handle_rpc_notification, {
      "method" => "item/completed",
      "params" => {
        "item" => {
          "type" => "commandExecution", "command" => "git diff --check",
          "status" => "completed", "exitCode" => 0
        }
      }
    })
    session.send(:handle_rpc_notification, {
      "method" => "turn/completed",
      "params" => Fixtures::Codex.turn_completed_notification(thread_id: "thr-proof", turn_id: "trn-proof")
    })

    rows = File.readlines(session.events_log_path).map { |line| JSON.parse(line) }
    completed = rows.find { |event| event["type"] == "task_complete" }
    assert_equal "completed_with_proof", completed.fetch("outcome_class")
    assert_equal "accepted", completed.fetch("artifact_report_status")
    result = Harnex::ArtifactReport.validate(session.artifact_report_path, final: true)
    assert result.ok
    assert_equal "no_change", result.report.dig("outcome", "status")
    assert_equal "harnex", result.report.dig("receipt", "author")
    assert_equal "changes_requested", result.report.dig("claims", "verdict")
    assert_equal 1, result.report.dig("claims", "findings", "P2")
    assert session.task_complete?
  ensure
    events_log = session&.instance_variable_get(:@events_log)
    events_log&.close unless events_log&.closed?
    output_log = session&.instance_variable_get(:@output_log)
    output_log&.close unless output_log&.closed?
  end

  def test_json_printed_in_final_prose_does_not_satisfy_required_sidecar
    report_path = File.join(@tmp, "missing-sidecar.json")
    session = Harnex::Session.new(
      adapter: Harnex::Adapters::CodexAppServer.new,
      command: ["codex", "app-server"],
      repo_root: @tmp,
      host: "127.0.0.1",
      id: "strict-prose-only",
      artifact_report_path: report_path,
      require_artifact_report: true
    )
    session.send(:prepare_output_log)
    session.send(:prepare_events_log)
    report_shaped_prose = JSON.generate(
      schema: Harnex::ArtifactReport::SCHEMA,
      status: "pass",
      outcome: { status: "accepted", summary: "Printed only." }
    )

    session.send(:handle_rpc_notification, {
      "method" => "item/completed",
      "params" => Fixtures::Codex.item_completed_agent_message(text: report_shaped_prose)
    })
    session.send(:handle_rpc_notification, {
      "method" => "turn/completed",
      "params" => Fixtures::Codex.turn_completed_notification(thread_id: "thr-prose", turn_id: "trn-prose")
    })

    rows = File.readlines(session.events_log_path).map { |line| JSON.parse(line) }
    failed = rows.find { |event| event["type"] == "task_failed" }
    assert_equal "completed_no_activity", failed.fetch("outcome_class")
    assert_equal "rejected", failed.fetch("artifact_report_status")
    receipt = Harnex::ArtifactReport.validate(session.artifact_report_path, final: true)
    refute receipt.ok
    assert_equal "rejected", receipt.report.dig("outcome", "status")
    refute receipt.report.key?("claims")
    refute session.task_complete?
  ensure
    events_log = session&.instance_variable_get(:@events_log)
    events_log&.close unless events_log&.closed?
    output_log = session&.instance_variable_get(:@output_log)
    output_log&.close unless output_log&.closed?
  end

  def test_item_completed_writes_synthesized_transcript_to_output_log
    text = "hello from codex"
    fanout("item/completed", Fixtures::Codex.item_completed_agent_message(text: text))

    log = output
    assert_match(/hello from codex/, log)
    assert log.end_with?("\n"), "synthesized text should be newline-terminated"
  end

  def test_tool_call_renders_one_line_summary
    fanout("item/completed", Fixtures::Codex.item_completed_tool_call(tool: "shell"))
    assert_match(/tool: shell/, output)
  end

  def test_error_notification_emits_error_event_without_disconnect_counter
    fanout("error", {
      "error" => { "message" => "stream broken", "codexErrorInfo" => "other" },
      "willRetry" => false,
      "threadId" => "thr-e",
      "turnId" => "trn-e"
    })

    rows = events
    error = rows.find { |e| e["type"] == "error" }
    refute_nil error
    assert_equal "stream broken", error["message"]
    assert_equal "other", error["codex_error_info"]
    assert_equal false, error["will_retry"]

    counters = @session.instance_variable_get(:@event_counters).snapshot
    assert_equal 0, counters[:disconnections]
  end

  def test_thread_compacted_records_compaction_counter
    fanout("thread/compacted", {})
    counters = @session.instance_variable_get(:@event_counters).snapshot
    assert_equal 1, counters[:compactions]
  end

  def test_token_usage_notification_stores_cumulative_total
    notif = Fixtures::Codex.thread_token_usage_updated_notification(
      thread_id: "thr-tok",
      turn_id: "trn-tok",
      token_usage: Fixtures::Codex.thread_token_usage(
        last: Fixtures::Codex.token_usage_breakdown(
          input_tokens: 70_000, output_tokens: 5_000, total_tokens: 75_000
        ),
        total: Fixtures::Codex.token_usage_breakdown(
          input_tokens: 100, output_tokens: 25, cached_input_tokens: 80,
          reasoning_output_tokens: 10, total_tokens: 125
        ),
        model_context_window: 200_000
      )
    )
    fanout("thread/tokenUsage/updated", notif)

    captured = @session.instance_variable_get(:@token_usage)
    assert_kind_of Hash, captured
    assert_equal 100, captured.dig("total", "inputTokens")
    assert_equal 25, captured.dig("total", "outputTokens")
    assert_equal 10, captured.dig("total", "reasoningOutputTokens")
    assert_equal 80, captured.dig("total", "cachedInputTokens")

    context = @session.send(:summary_from_token_usage).fetch(:context)
    assert_equal "estimated", context.fetch(:status)
    assert_equal "codex_thread_token_usage_last", context.fetch(:source)
    assert_equal 75_000, context.fetch(:terminal_tokens)
    assert_equal 200_000, context.fetch(:window_tokens)
    assert_equal 37.5, context.fetch(:terminal_percent)
  end

  def test_jsonrpc_session_writes_token_usage_to_dispatch_row
    adapter = Harnex::Adapters::CodexAppServer.new
    session = build_jsonrpc_session(adapter, id: "tok-dispatch")
    session.send(:prepare_output_log)
    session.send(:prepare_events_log)
    session.send(:emit_started_event)
    session.send(:emit_git_start_event)
    session.send(:handle_rpc_notification, {
      "method" => "thread/started",
      "params" => Fixtures::Codex.thread_started_notification(thread_id: "thr-tok")
    })
    session.send(:handle_rpc_notification, {
      "method" => "turn/completed",
      "params" => Fixtures::Codex.turn_completed_notification(thread_id: "thr-tok", turn_id: "trn-tok")
    })

    notif = Fixtures::Codex.thread_token_usage_updated_notification(
      thread_id: "thr-tok",
      turn_id: "trn-tok",
      token_usage: Fixtures::Codex.thread_token_usage(
        last: Fixtures::Codex.token_usage_breakdown(
          input_tokens: 72_000, output_tokens: 8_000, total_tokens: 80_000
        ),
        total: Fixtures::Codex.token_usage_breakdown(
          input_tokens: 197_819, output_tokens: 25_018,
          cached_input_tokens: 6_408_576, reasoning_output_tokens: 12_501,
          total_tokens: 222_837
        ),
        model_context_window: 200_000
      )
    )
    session.send(:handle_rpc_notification, { "method" => "thread/tokenUsage/updated", "params" => notif })
    session.instance_variable_set(:@exit_code, 0)
    session.send(:finalize_session!)

    record = JSON.parse(File.read(dispatch_stream_path).lines.last)
    assert_equal 197_819, record.dig("actual", "input_tokens")
    assert_equal 25_018, record.dig("actual", "output_tokens")
    assert_equal 12_501, record.dig("actual", "reasoning_tokens")
    assert_equal 6_408_576, record.dig("actual", "cached_tokens")
    assert_equal 222_837, record.dig("actual", "total_tokens")
    assert_equal "thr-tok", record.dig("actual", "agent_session_id")
    assert_equal "stdio_jsonrpc", record.dig("actual", "adapter_transport")
    assert_equal true, record.dig("actual", "task_complete")
    assert_equal 0, record.dig("actual", "exit_code")
    assert_nil record.dig("actual", "signal")
    assert_nil record.dig("actual", "last_error")
    assert_equal "estimated", record.dig("context", "status")
    assert_equal "codex_thread_token_usage_last", record.dig("context", "source")
    assert_equal 80_000, record.dig("context", "terminal_tokens")
    assert_equal 200_000, record.dig("context", "window_tokens")
    assert_equal 40.0, record.dig("context", "terminal_percent")
    assert_equal 80_000, record.dig("context", "peak_tokens")
    assert_equal 40.0, record.dig("context", "peak_percent")
  end

  def test_jsonrpc_session_with_no_token_usage_keeps_token_fields_null
    adapter = Harnex::Adapters::CodexAppServer.new
    session = build_jsonrpc_session(adapter, id: "tok-empty")
    session.send(:prepare_output_log)
    session.send(:prepare_events_log)
    session.send(:emit_started_event)
    session.send(:emit_git_start_event)

    session.instance_variable_set(:@exit_code, 0)
    session.send(:finalize_session!)

    record = JSON.parse(File.read(dispatch_stream_path).lines.last)
    assert_nil record.dig("actual", "input_tokens")
    assert_nil record.dig("actual", "output_tokens")
    assert_nil record.dig("actual", "reasoning_tokens")
    assert_nil record.dig("actual", "cached_tokens")
  end

  def test_classify_exit_marks_short_pre_turn_jsonrpc_exit_as_boot_failure
    @session.instance_variable_set(:@exit_code, nil)
    @session.instance_variable_set(:@ended_at, @session.instance_variable_get(:@started_at) + 1)

    assert_equal "boot_failure", @session.send(:classify_exit)
  end

  def test_classify_exit_keeps_post_turn_short_exit_as_disconnected
    fanout("turn/started",
      Fixtures::Codex.turn_started_notification(thread_id: "thr-boot", turn_id: "trn-boot"))
    @session.instance_variable_set(:@exit_code, 0)
    @session.instance_variable_set(:@ended_at, @session.instance_variable_get(:@started_at) + 1)

    assert_equal "disconnected", @session.send(:classify_exit)
  end

  def test_failed_turn_emits_task_failed_and_classifies_failure
    fanout("turn/started",
      Fixtures::Codex.turn_started_notification(thread_id: "thr-fail", turn_id: "trn-fail"))
    fanout("turn/completed", {
      "threadId" => "thr-fail",
      "turn" => {
        "id" => "trn-fail",
        "status" => "failed",
        "error" => { "message" => "Missing environment variable: `AZURE_OPENAI_API_KEY`.", "codexErrorInfo" => "other" }
      }
    })

    failed = events.find { |e| e["type"] == "task_failed" }
    refute_nil failed
    assert_equal "trn-fail", failed["turnId"]
    assert_equal "failed", failed["status"]
    assert_match(/AZURE_OPENAI_API_KEY/, failed["message"])

    payload = @session.status_payload(include_input_state: false)
    assert_equal false, payload[:task_complete]
    assert_equal true, payload[:task_failed]
    assert_equal false, payload[:done]
    assert_equal "failed", payload[:work_state]
    assert_match(/AZURE_OPENAI_API_KEY/, payload[:last_error])

    @session.instance_variable_set(:@exit_code, 0)
    @session.instance_variable_set(:@ended_at, @session.instance_variable_get(:@started_at) + 2)
    assert_equal "failure", @session.send(:classify_exit)
  end

  def test_classify_exit_keeps_late_pre_turn_exit_as_disconnected
    @session.instance_variable_set(:@exit_code, 0)
    @session.instance_variable_set(:@ended_at, @session.instance_variable_get(:@started_at) + 6)

    assert_equal "disconnected", @session.send(:classify_exit)
  end

  def test_inject_via_jsonrpc_calls_dispatch
    server_in, client_out = IO.pipe
    client_in, server_out = IO.pipe

    server = Thread.new do
      req = JSON.parse(server_in.gets)
      server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: {} }) + "\n")
      server_out.flush
      server_in.gets # initialized notification
      req = JSON.parse(server_in.gets) # thread/start
      server_out.write(JSON.generate({
        jsonrpc: "2.0", id: req["id"],
        result: Fixtures::Codex.thread_start_response(id: "thr-i")
      }) + "\n")
      server_out.flush
      req = JSON.parse(server_in.gets) # turn/start
      server_out.write(JSON.generate({
        jsonrpc: "2.0", id: req["id"],
        result: Fixtures::Codex.turn_start_response(id: "trn-i")
      }) + "\n")
      server_out.flush
    end

    @adapter.start_rpc(read_io: client_in, write_io: client_out, pid: nil)
    result = @session.inject_via_adapter(text: "do thing", submit: true, enter_only: false)

    assert result[:ok]
    assert_equal "trn-i", result[:turn_id]
    assert_equal "codex", result[:cli]

    types = events.map { |e| e["type"] }
    assert_includes types, "send"
  ensure
    server&.join(1)
    @adapter.close
    [server_in, client_out, client_in, server_out].each { |io| io.close rescue nil }
  end

  def test_jsonrpc_session_dispatches_initial_appserver_context
    adapter = Harnex::Adapters::CodexAppServer.new(["[harnex session id=ax-29-a] ok"])
    session = build_jsonrpc_session(adapter, id: "test-context")
    turn_requests = Queue.new
    handles = start_session_with_stubbed_rpc(adapter: adapter, session: session, turn_requests: turn_requests)

    assert wait_for { !turn_requests.empty? }, "expected initial context to dispatch a turn"
    request = turn_requests.pop

    assert_equal "turn/start", request["method"]
    assert_equal "thr-session", request.dig("params", "threadId")
    assert_equal "[harnex session id=ax-29-a] ok",
      request.dig("params", "input", 0, "text")
  ensure
    close_stubbed_rpc(handles) if handles
  end

  def test_jsonrpc_run_writes_boot_failure_summary_when_initial_turn_errors
    adapter = Harnex::Adapters::CodexAppServer.new(["[harnex session id=boot-fail] echo OK"])
    session = build_jsonrpc_session(adapter, id: "boot-fail")
    server_in, client_out = IO.pipe
    client_in, server_out = IO.pipe
    original_start = adapter.method(:start_rpc)

    adapter.define_singleton_method(:start_rpc) do |env: nil, cwd: nil|
      original_start.call(env: env, cwd: cwd, read_io: client_in, write_io: client_out, pid: nil)
    end

    server = Thread.new do
      req = JSON.parse(server_in.gets)
      server_out.write(JSON.generate({ jsonrpc: "2.0", id: req["id"], result: {} }) + "\n")
      server_out.flush
      server_in.gets # initialized notification

      req = JSON.parse(server_in.gets)
      server_out.write(JSON.generate({
        jsonrpc: "2.0",
        id: req["id"],
        result: Fixtures::Codex.thread_start_response(id: "thr-boot-fail")
      }) + "\n")
      server_out.flush

      req = JSON.parse(server_in.gets)
      server_out.write(JSON.generate({
        jsonrpc: "2.0",
        id: req["id"],
        error: {
          code: -32_000,
          message: "Invalid request: invalid type: null, expected a string"
        }
      }) + "\n")
      server_out.flush
    rescue IOError, Errno::EPIPE
      nil
    end

    err = assert_raises(StandardError) { session.run(validate_binary: false) }
    assert_match(/Invalid request: invalid type: null/, err.message)

    rows = File.readlines(session.events_log_path).map { |line| JSON.parse(line) }
    assert_equal %w[started attempt_started task_failed usage summary attempt_finished exited], rows.map { |row| row["type"] }
    assert_equal "boot_failure", rows[-3]["exit"]
    assert_equal "boot_failure", rows[-1]["reason"]

    record = JSON.parse(File.read(dispatch_stream_path).lines.last)
    assert_equal "boot-fail", record.dig("meta", "id")
    assert_kind_of String, record.dig("meta", "started_at")
    assert_kind_of String, record.dig("meta", "ended_at")
    assert_equal "boot_failure", record.dig("actual", "exit")
    assert_equal 1, record.dig("actual", "disconnections")
    assert_operator record.dig("actual", "duration_s"), :<=, 5
    assert_equal(
      "Invalid request: invalid type: null, expected a string",
      record.dig("actual", "last_error")
    )
  ensure
    server&.join(1)
    [server_out, client_out, client_in, server_in].each do |io|
      io.close unless io.closed?
    rescue StandardError
      nil
    end
  end

  def test_jsonrpc_inbox_delivers_harnex_send_when_prompt
    adapter = Harnex::Adapters::CodexAppServer.new
    session = build_jsonrpc_session(adapter, id: "test-send")
    turn_requests = Queue.new
    handles = start_session_with_stubbed_rpc(adapter: adapter, session: session, turn_requests: turn_requests)

    assert wait_for { session.status_payload(include_input_state: false)[:agent_state] == "prompt" },
      "expected JSON-RPC session state machine to become prompt"

    result = session.inbox.enqueue(text: "hello", submit: true, enter_only: false)

    assert_equal true, result[:ok]
    assert_equal "delivered", result[:status]
    assert wait_for { !turn_requests.empty? }, "expected harnex send to dispatch a turn"

    request = turn_requests.pop
    assert_equal "turn/start", request["method"]
    assert_equal "hello", request.dig("params", "input", 0, "text")
  ensure
    close_stubbed_rpc(handles) if handles
  end
end
