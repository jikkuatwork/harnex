require_relative "../test_helper"

class CoreTest < Minitest::Test
  def with_active_session_ids(ids)
    singleton = Harnex.singleton_class
    original = Harnex.method(:active_session_ids)
    singleton.send(:define_method, :active_session_ids) { |_repo_root| ids }
    yield
  ensure
    singleton.send(:define_method, :active_session_ids, original)
  end

  # --- normalize_id ---

  def test_normalize_id_strips_whitespace
    assert_equal "hello", Harnex.normalize_id("  hello  ")
  end

  def test_normalize_id_raises_on_empty
    assert_raises(RuntimeError) { Harnex.normalize_id("") }
    assert_raises(RuntimeError) { Harnex.normalize_id("   ") }
  end

  def test_normalize_id_preserves_case
    assert_equal "MyWorker", Harnex.normalize_id("MyWorker")
  end

  # --- id_key ---

  def test_id_key_lowercases_and_slugifies
    assert_equal "my-worker", Harnex.id_key("My Worker")
  end

  def test_id_key_strips_leading_trailing_dashes
    assert_equal "abc", Harnex.id_key("--abc--")
  end

  def test_id_key_collapses_non_alnum_runs
    assert_equal "a-b-c", Harnex.id_key("a!!b@@c")
  end

  # --- id_key used consistently for matching (bug #4 fix) ---

  def test_id_key_collapses_case_variants
    # "Worker-1" and "worker_1" both map to the same id_key
    refute_equal Harnex.normalize_id("Worker-1"), Harnex.normalize_id("worker_1")
    assert_equal Harnex.id_key("Worker-1"), Harnex.id_key("worker_1")
  end

  # --- cli_key ---

  def test_cli_key_normalizes
    assert_equal "codex", Harnex.cli_key("Codex")
    assert_equal "claude", Harnex.cli_key("claude")
  end

  def test_cli_key_returns_nil_for_empty
    assert_nil Harnex.cli_key("")
    assert_nil Harnex.cli_key("  ")
  end

  # --- repo_key ---

  def test_repo_key_returns_hex_prefix
    key = Harnex.repo_key("/tmp/fake-repo")
    assert_match(/\A[0-9a-f]{16}\z/, key)
  end

  def test_repo_key_deterministic
    assert_equal Harnex.repo_key("/foo"), Harnex.repo_key("/foo")
  end

  def test_repo_key_differs_for_different_paths
    refute_equal Harnex.repo_key("/foo"), Harnex.repo_key("/bar")
  end

  # --- registry_path ---

  def test_registry_path_uses_repo_key_and_id_key
    path = Harnex.registry_path("/tmp/repo", "MyWorker")
    assert path.end_with?("#{Harnex.repo_key('/tmp/repo')}--myworker.json")
  end

  def test_registry_path_defaults_empty_slug_to_default
    # id_key of a string that normalizes to just dashes => "default"
    path = Harnex.registry_path("/tmp/repo", "---")
    assert path.end_with?("--default.json")
  end

  # --- format_relay_message ---

  def test_format_relay_message_with_body
    t = Time.parse("2026-01-15T10:00:00Z")
    msg = Harnex.format_relay_message("hello world", from: "codex", id: "worker-1", at: t)
    assert msg.start_with?("[harnex relay from=codex id=worker-1 at=")
    assert msg.include?("hello world")
    assert msg.include?("\n")
  end

  def test_format_relay_message_empty_body
    t = Time.parse("2026-01-15T10:00:00Z")
    msg = Harnex.format_relay_message("", from: "claude", id: "main", at: t)
    assert msg.start_with?("[harnex relay from=claude id=main at=")
    refute msg.include?("\n")
  end

  # --- current_session_context ---

  def test_current_session_context_returns_nil_when_missing
    env = {}
    assert_nil Harnex.current_session_context(env)
  end

  def test_current_session_context_returns_hash_when_present
    env = {
      "HARNEX_SESSION_ID" => "abc123",
      "HARNEX_SESSION_CLI" => "codex",
      "HARNEX_ID" => "worker-1",
      "HARNEX_SESSION_REPO_ROOT" => "/tmp/repo"
    }
    ctx = Harnex.current_session_context(env)
    assert_equal "abc123", ctx[:session_id]
    assert_equal "codex", ctx[:cli]
    assert_equal "worker-1", ctx[:id]
    assert_equal "/tmp/repo", ctx[:repo_root]
  end

  def test_current_session_context_returns_nil_without_harnex_id
    env = {
      "HARNEX_SESSION_ID" => "abc123",
      "HARNEX_SESSION_CLI" => "codex"
    }
    assert_nil Harnex.current_session_context(env)
  end

  # --- generate_id ---

  def test_generate_id_returns_adjective_noun
    with_active_session_ids(Set.new) do
      id = Harnex.generate_id("/tmp/repo")
      assert_match(/\A[a-z]+-[a-z]+\z/, id)
    end
  end

  def test_generate_id_avoids_collisions
    with_active_session_ids(Set["bold-ant"]) do
      id = Harnex.generate_id("/tmp/repo")
      refute_equal "bold-ant", id
    end
  end

  def test_generate_id_falls_back_when_word_space_is_exhausted
    taken = Harnex::ID_ADJECTIVES.product(Harnex::ID_NOUNS).map { |adj, noun| "#{adj}-#{noun}" }.to_set

    with_active_session_ids(taken) do
      id = Harnex.generate_id("/tmp/repo")
      assert_match(/\Asession-[0-9a-f]{8}\z/, id)
    end
  end

  # --- exit_status_path (bug #2 fix: includes repo_key) ---

  def test_exit_status_path_includes_repo_key
    path = Harnex.exit_status_path("/tmp/repo", "worker-1")
    assert path.include?(Harnex.repo_key("/tmp/repo"))
    assert path.end_with?("--worker-1.json")
    assert path.include?("exits")
  end

  def test_exit_status_path_differs_across_repos
    a = Harnex.exit_status_path("/tmp/repo-a", "worker")
    b = Harnex.exit_status_path("/tmp/repo-b", "worker")
    refute_equal a, b
  end

  # --- output_log_path ---

  def test_output_log_path_includes_repo_key
    path = Harnex.output_log_path("/tmp/repo", "worker-1")
    assert path.include?(Harnex.repo_key("/tmp/repo"))
    assert path.end_with?("--worker-1.log")
    assert path.include?("output")
  end

  def test_output_log_path_differs_across_repos
    a = Harnex.output_log_path("/tmp/repo-a", "worker")
    b = Harnex.output_log_path("/tmp/repo-b", "worker")
    refute_equal a, b
  end

  # --- allocate_port ---

  def test_allocate_port_returns_integer
    port = Harnex.allocate_port("/tmp/fake", "test-id")
    assert_kind_of Integer, port
    assert port >= Harnex::DEFAULT_BASE_PORT
    assert port < Harnex::DEFAULT_BASE_PORT + Harnex::DEFAULT_PORT_SPAN
  end

  def test_allocate_port_deterministic_seed
    a = Harnex.allocate_port("/tmp/fake", "test-id")
    b = Harnex.allocate_port("/tmp/fake", "test-id")
    assert_equal a, b
  end

  def test_allocate_port_respects_requested_port
    # Use a high ephemeral port that's likely free
    port = Harnex.allocate_port("/tmp/fake", "test-id", 59876)
    assert_equal 59876, port
  end
end
