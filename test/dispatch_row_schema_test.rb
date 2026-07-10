require_relative "test_helper"
require "json"

class DispatchRowSchemaTest < Minitest::Test
  AGENT_KEYS = %w[
    adapter_transport
    cli
    model_effective
    model_requested
    provider
    reasoning_effort
    service_tier
  ].freeze

  ACTUAL_KEYS = %w[
    adapter_transport
    agent_session_id
    cached_tokens
    commands_executed
    commits
    compactions
    cost_usd
    disconnections
    duration_s
    effort
    event_records
    events_log_path
    exit
    exit_code
    files_changed
    force_resumes
    input_tokens
    last_error
    lines_changed
    loc_added
    loc_removed
    model
    output_bytes
    output_lines
    output_log_path
    output_tokens
    rate_limits
    reasoning_tokens
    signal
    stalls
    task_complete
    tool_calls
    total_tokens
    turn_count
  ].freeze

  META_KEYS = %w[
    agent
    agent_provider
    agent_version
    branch
    chain_id
    description
    end_sha
    ended_at
    harness
    harness_version
    host
    id
    issue
    orchestrator
    orchestrator_session
    parent_dispatch_id
    phase
    plan
    platform
    repo
    start_sha
    started_at
    task_brief
    tier
    tmux_session
  ].freeze

  QUEUE_KEYS = %w[
    entry_id
    entry_title
    intent
    issue
    phase
    plan
    project_id
    queue_id
    tier
  ].freeze

  RELIABILITY_KEYS = %w[
    adapter_close
    compactions
    force_resumes
    real_disconnections
    recovered
    stalls
    stream_interruptions
  ].freeze

  def test_dispatch_row_schema_includes_tier1_fields_and_stable_types
    Dir.mktmpdir("harnex-dispatch-schema") do |repo|
      init_git_repo(repo)

      id = "schema-worker"
      summary_path = File.join(repo, "koder", "DISPATCH.jsonl")
      adapter = build_stubbed_codex_adapter("codex-test-1.0.0")
      session = Harnex::Session.new(
        adapter: adapter,
        command: [RbConfig.ruby, "-e", codex_summary_script],
        repo_root: repo,
        host: "127.0.0.1",
        id: id,
        description: "schema row",
        meta: {
          "model" => "gpt-5.3-codex",
          "effort" => "high",
          "orchestrator" => "holm",
          "orchestrator_session" => "orch-1",
          "chain_id" => "chain-1",
          "parent_dispatch_id" => "parent-1",
          "tier" => "1",
          "phase" => "tdd",
          "issue" => "35",
          "plan" => "tier-1",
          "task_brief" => "dispatch telemetry hygiene",
          "project_id" => "harnex",
          "queue_id" => "queue-005",
          "entry_id" => "SP-4",
          "entry_title" => "Dispatch telemetry hygiene",
          "intent" => "telemetry-contract"
        },
        summary_out: summary_path
      )
      write_tmux_registry(repo, id, tmux_session: "schema-tmux")
      silence_session_stdout(session)

      assert_equal 0, session.run(validate_binary: false)

      record = JSON.parse(File.read(summary_path).lines.last)
      assert_equal %w[actual agent meta predicted queue reliability], record.keys.sort
      assert_equal META_KEYS, record.fetch("meta").keys.sort
      assert_equal ACTUAL_KEYS, record.fetch("actual").keys.sort
      assert_equal AGENT_KEYS, record.fetch("agent").keys.sort
      assert_equal QUEUE_KEYS, record.fetch("queue").keys.sort
      assert_equal RELIABILITY_KEYS, record.fetch("reliability").keys.sort

      meta = record.fetch("meta")
      assert_equal id, meta.fetch("id")
      assert_equal "schema-tmux", meta.fetch("tmux_session")
      assert_equal "schema row", meta.fetch("description")
      assert_equal "harnex", meta.fetch("harness")
      assert_kind_of String, meta.fetch("harness_version")
      assert_equal "codex", meta.fetch("agent")
      assert_equal "codex-test-1.0.0", meta.fetch("agent_version")
      assert_equal "openai", meta.fetch("agent_provider")
      assert_kind_of String, meta.fetch("host")
      assert_kind_of String, meta.fetch("platform")
      assert_equal "holm", meta.fetch("orchestrator")
      assert_equal "orch-1", meta.fetch("orchestrator_session")
      assert_equal "chain-1", meta.fetch("chain_id")
      assert_equal "parent-1", meta.fetch("parent_dispatch_id")
      assert_equal "1", meta.fetch("tier")
      assert_equal "tdd", meta.fetch("phase")
      assert_equal "35", meta.fetch("issue")
      assert_equal "tier-1", meta.fetch("plan")
      assert_equal "dispatch telemetry hygiene", meta.fetch("task_brief")
      assert_equal repo, meta.fetch("repo")
      assert_kind_of String, meta.fetch("branch")
      assert_match(/\A[0-9a-f]{40}\z/, meta.fetch("start_sha"))
      assert_match(/\A[0-9a-f]{40}\z/, meta.fetch("end_sha"))
      assert_kind_of String, meta.fetch("started_at")
      assert_kind_of String, meta.fetch("ended_at")

      agent = record.fetch("agent")
      assert_equal "codex", agent.fetch("cli")
      assert_equal "openai", agent.fetch("provider")
      assert_equal "gpt-5.3-codex", agent.fetch("model_requested")
      assert_equal "gpt-5.3-codex", agent.fetch("model_effective")
      assert_equal "high", agent.fetch("reasoning_effort")
      assert_nil agent.fetch("service_tier")
      assert_equal "pty", agent.fetch("adapter_transport")

      queue = record.fetch("queue")
      assert_equal "harnex", queue.fetch("project_id")
      assert_equal "queue-005", queue.fetch("queue_id")
      assert_equal "SP-4", queue.fetch("entry_id")
      assert_equal "Dispatch telemetry hygiene", queue.fetch("entry_title")
      assert_equal "35", queue.fetch("issue")
      assert_equal "tier-1", queue.fetch("plan")
      assert_equal "tdd", queue.fetch("phase")
      assert_equal "1", queue.fetch("tier")
      assert_equal "telemetry-contract", queue.fetch("intent")

      reliability = record.fetch("reliability")
      assert_equal "normal", reliability.fetch("adapter_close")
      assert_equal 0, reliability.fetch("real_disconnections")
      assert_equal 0, reliability.fetch("stream_interruptions")
      assert_kind_of Integer, reliability.fetch("stalls")
      assert_kind_of Integer, reliability.fetch("force_resumes")
      assert_kind_of Integer, reliability.fetch("compactions")
      assert_equal false, reliability.fetch("recovered")

      actual = record.fetch("actual")
      assert_equal "gpt-5.3-codex", actual.fetch("model")
      assert_equal "high", actual.fetch("effort")
      assert_kind_of Integer, actual.fetch("duration_s")
      assert_equal 104_158, actual.fetch("input_tokens")
      assert_equal 2_709, actual.fetch("output_tokens")
      assert_equal 870, actual.fetch("reasoning_tokens")
      assert_equal 250_880, actual.fetch("cached_tokens")
      assert_equal 106_867, actual.fetch("total_tokens")
      assert_nil actual.fetch("cost_usd")
      assert_equal "019ddf05-0f03-7d70-904f-23db7f00640f", actual.fetch("agent_session_id")
      assert_equal "pty", actual.fetch("adapter_transport")
      assert_equal false, actual.fetch("task_complete")
      assert_equal "success", actual.fetch("exit")
      assert_equal 0, actual.fetch("exit_code")
      assert_nil actual.fetch("signal")
      assert_nil actual.fetch("last_error")
      assert_kind_of Integer, actual.fetch("loc_added")
      assert_kind_of Integer, actual.fetch("loc_removed")
      assert_kind_of Integer, actual.fetch("lines_changed")
      assert_kind_of Integer, actual.fetch("files_changed")
      assert_kind_of Integer, actual.fetch("commits")
      assert_kind_of Integer, actual.fetch("stalls")
      assert_kind_of Integer, actual.fetch("force_resumes")
      assert_kind_of Integer, actual.fetch("disconnections")
      assert_kind_of Integer, actual.fetch("compactions")
      assert_kind_of Integer, actual.fetch("turn_count")
      assert_kind_of Integer, actual.fetch("tool_calls")
      assert_kind_of Integer, actual.fetch("commands_executed")
      assert_nil actual.fetch("rate_limits")
      assert_kind_of Integer, actual.fetch("output_lines")
      assert_kind_of Integer, actual.fetch("output_bytes")
      assert_kind_of Integer, actual.fetch("event_records")
      assert_equal Harnex.output_log_path(repo, id), actual.fetch("output_log_path")
      assert_equal Harnex.events_log_path(repo, id), actual.fetch("events_log_path")
    end
  end

  def test_dispatch_row_tmux_session_is_null_for_headless_sessions
    Dir.mktmpdir("harnex-dispatch-headless") do |repo|
      id = "schema-headless"
      summary_path = File.join(repo, "DISPATCH.jsonl")
      session = Harnex::Session.new(
        adapter: build_stubbed_codex_adapter("codex-test-1.0.0"),
        command: [RbConfig.ruby, "-e", codex_summary_script],
        repo_root: repo,
        host: "127.0.0.1",
        id: id,
        summary_out: summary_path
      )
      silence_session_stdout(session)

      assert_equal 0, session.run(validate_binary: false)

      record = JSON.parse(File.read(summary_path).lines.last)
      assert_nil record.fetch("meta").fetch("tmux_session")
      assert record.key?("agent")
      assert record.key?("reliability")
      refute record.key?("queue")
    end
  end

  def test_agent_version_probe_returns_string_for_real_binary
    adapter = Harnex::Adapters::Generic.new(RbConfig.ruby)
    version = adapter.agent_version

    assert_kind_of String, version
    refute_empty version
  end

  def test_agent_version_probe_returns_nil_for_missing_binary
    adapter = Harnex::Adapters::Generic.new("harnex-nonexistent-binary-#{Process.pid}")

    assert_nil adapter.agent_version
  end

  private

  def build_stubbed_codex_adapter(version)
    adapter = Harnex::Adapters::Codex.new
    adapter.define_singleton_method(:agent_version) { version }
    adapter
  end

  def codex_summary_script
    <<~RUBY
      puts "Token usage: total=106,867 input=104,158 (+ 250,880 cached) output=2,709 (reasoning 870)"
      puts "To continue this session, run codex resume 019ddf05-0f03-7d70-904f-23db7f00640f"
    RUBY
  end

  def init_git_repo(repo)
    system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
    File.write(File.join(repo, "README.md"), "one\n")
    system("git", "-C", repo, "add", "README.md", out: File::NULL, err: File::NULL)
    system(
      "git", "-C", repo,
      "-c", "user.email=test@example.com",
      "-c", "user.name=Test",
      "commit", "-q", "-m", "initial",
      out: File::NULL, err: File::NULL
    )
  end

  def write_tmux_registry(repo, id, tmux_session:)
    Harnex.write_registry(
      Harnex.registry_path(repo, id),
      {
        "tmux_session" => tmux_session,
        "tmux_target" => "%99",
        "tmux_window" => "worker"
      }
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
