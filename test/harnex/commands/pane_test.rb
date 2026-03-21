require_relative "../../test_helper"

class PaneCommandTest < Minitest::Test
  def setup
    @repo_root = Dir.mktmpdir("harnex-pane-repo")
    @other_repo_root = Dir.mktmpdir("harnex-pane-other-repo")
    @third_repo_root = Dir.mktmpdir("harnex-pane-third-repo")
    [@repo_root, @other_repo_root, @third_repo_root].each { |path| init_repo(path) }
    @paths = []
  end

  def teardown
    @paths.each { |path| FileUtils.rm_f(path) }
    FileUtils.rm_rf(@repo_root)
    FileUtils.rm_rf(@other_repo_root)
    FileUtils.rm_rf(@third_repo_root)
  end

  def test_help_returns_zero
    pane = Harnex::Pane.new(["--help"])
    assert_output(/Usage: harnex pane/) { assert_equal 0, pane.run }
  end

  def test_requires_id
    pane = Harnex::Pane.new(["--repo", @repo_root])
    error = assert_raises(RuntimeError) { pane.run }

    assert_equal "--id is required for harnex pane", error.message
  end

  def test_rejects_non_positive_lines
    pane = Harnex::Pane.new(["--id", "pane-session", "--repo", @repo_root, "--lines", "0"])
    error = assert_raises(OptionParser::InvalidArgument) { pane.run }

    assert_equal "invalid argument: --lines must be >= 1", error.message
  end

  def test_returns_1_when_session_not_found
    pane = Harnex::Pane.new(["--id", "missing", "--repo", @repo_root])
    assert_output(nil, /no active session found/) { assert_equal 1, pane.run }
  end

  def test_reports_ambiguous_cross_repo_matches
    write_registry("pane-session", repo_root: @other_repo_root, tmux_target: "%41")
    write_registry("pane-session", repo_root: @third_repo_root, tmux_target: "%42")

    Dir.chdir(@repo_root) do
      pane = Harnex::Pane.new(["--id", "pane-session"])
      assert_output(nil, /multiple active sessions found/) { assert_equal 1, pane.run }
    end
  end

  def test_returns_1_when_tmux_is_unavailable
    write_registry("pane-session", tmux_target: "%42")
    pane = Harnex::Pane.new(["--id", "pane-session", "--repo", @repo_root])
    calls = []
    pane.define_singleton_method(:system) do |*args, **_kwargs|
      calls << args
      false
    end

    assert_output(nil, /tmux is not installed/) { assert_equal 1, pane.run }
    assert_equal [["tmux", "-V"]], calls
  end

  def test_returns_1_when_session_is_not_tmux_backed
    write_registry("pane-session", tmux_target: "%42")
    pane = Harnex::Pane.new(["--id", "pane-session", "--repo", @repo_root])
    pane.define_singleton_method(:system) do |*args, **_kwargs|
      case args
      when ["tmux", "-V"]
        true
      when ["tmux", "has-session", "-t", "%42"]
        false
      else
        raise "unexpected system call: #{args.inspect}"
      end
    end

    assert_output(nil, /tmux target "%42" no longer exists/) { assert_equal 1, pane.run }
  end

  def test_successful_capture_outputs_text
    write_registry("pane-session", tmux_target: "%42")
    pane = Harnex::Pane.new(["--id", "pane-session", "--repo", @repo_root])
    status = successful_status
    stub_tmux_system(pane, "%42")
    pane.define_singleton_method(:capture_command) do |command|
      expected = ["tmux", "capture-pane", "-t", "%42", "-p"]
      raise "unexpected capture command: #{command.inspect}" unless command == expected

      ["prompt>\n", "", status]
    end

    out, = capture_io { assert_equal 0, pane.run }
    assert_equal "prompt>\n", out
  end

  def test_lines_flag_passes_start_offset_to_tmux_capture
    write_registry("pane-session", tmux_target: "%42")
    pane = Harnex::Pane.new(["--id", "pane-session", "--repo", @repo_root, "--lines", "20"])
    status = successful_status
    stub_tmux_system(pane, "%42")

    captured_command = nil
    pane.define_singleton_method(:capture_command) do |command|
      captured_command = command
      ["tail\n", "", status]
    end

    capture_io { assert_equal 0, pane.run }
    assert_equal ["tmux", "capture-pane", "-t", "%42", "-p", "-S", "-20"], captured_command
  end

  def test_json_wraps_capture_with_metadata
    write_registry("pane-session", tmux_target: "%42")
    pane = Harnex::Pane.new(["--id", "pane-session", "--repo", @repo_root, "--json", "--lines", "5"])
    status = successful_status
    stub_tmux_system(pane, "%42")
    pane.define_singleton_method(:capture_command) do |_command|
      ["line 1\nline 2\n", "", status]
    end

    out, = capture_io { assert_equal 0, pane.run }
    payload = JSON.parse(out)

    assert_equal true, payload["ok"]
    assert_equal "pane-session", payload["id"]
    assert_equal 5, payload["lines"]
    assert_equal "line 1\nline 2\n", payload["text"]
    refute_nil payload["captured_at"]
  end

  def test_follow_refreshes_until_pid_exits
    write_registry("pane-session", pid: Process.pid, tmux_target: "%42")
    pane = Harnex::Pane.new(["--id", "pane-session", "--repo", @repo_root, "--follow", "--interval", "0"])
    status = successful_status

    stub_tmux_system(pane, "%42")

    call_count = 0
    pane.define_singleton_method(:capture_command) do |_command|
      call_count += 1
      ["screen #{call_count}\n", "", status]
    end

    original_alive = Harnex.method(:alive_pid?)
    Harnex.define_singleton_method(:alive_pid?) do |pid|
      call_count >= 2 ? false : original_alive.call(pid)
    end

    out, = capture_io { assert_equal 0, pane.run }

    assert_operator call_count, :>=, 2
    assert_includes out, "screen"
  ensure
    Harnex.define_singleton_method(:alive_pid?, &original_alive) if original_alive
  end

  def test_follow_only_redraws_on_change
    write_registry("pane-session", pid: Process.pid, tmux_target: "%42")
    pane = Harnex::Pane.new(["--id", "pane-session", "--repo", @repo_root, "--follow", "--interval", "0"])
    status = successful_status

    stub_tmux_system(pane, "%42")

    call_count = 0
    pane.define_singleton_method(:capture_command) do |_command|
      call_count += 1
      ["same screen\n", "", status]
    end

    original_alive = Harnex.method(:alive_pid?)
    Harnex.define_singleton_method(:alive_pid?) do |pid|
      call_count >= 3 ? false : original_alive.call(pid)
    end

    out, = capture_io { pane.run }

    assert_equal 3, call_count
    assert_equal 1, out.scan("\e[H\e[2J").length
  ensure
    Harnex.define_singleton_method(:alive_pid?, &original_alive) if original_alive
  end

  def test_discovers_tmux_target_from_session_pid_and_persists_it
    path = write_registry("pane-session", pid: Process.pid)
    pane = Harnex::Pane.new(["--id", "pane-session", "--repo", @repo_root])
    status = successful_status
    discovery = { target: "%91", session_name: "harnex", window_name: "cx-91" }
    original_tmux_lookup = Harnex.method(:tmux_pane_for_pid)
    Harnex.define_singleton_method(:tmux_pane_for_pid) { |_pid| discovery }

    stub_tmux_system(pane, "%91")
    pane.define_singleton_method(:capture_command) do |command|
      expected = ["tmux", "capture-pane", "-t", "%91", "-p"]
      raise "unexpected capture command: #{command.inspect}" unless command == expected

      ["prompt>\n", "", status]
    end

    out, = capture_io { assert_equal 0, pane.run }
    assert_equal "prompt>\n", out

    payload = JSON.parse(File.read(path))
    assert_equal "%91", payload["tmux_target"]
    assert_equal "harnex", payload["tmux_session"]
    assert_equal "cx-91", payload["tmux_window"]
  ensure
    Harnex.define_singleton_method(:tmux_pane_for_pid, &original_tmux_lookup) if original_tmux_lookup
  end

  def test_falls_back_to_unique_cross_repo_session_when_current_repo_has_no_match
    write_registry("pane-session", repo_root: @other_repo_root, tmux_target: "%77")
    pane = nil
    status = successful_status

    Dir.chdir(@repo_root) do
      pane = Harnex::Pane.new(["--id", "pane-session"])
    end

    stub_tmux_system(pane, "%77")
    pane.define_singleton_method(:capture_command) do |command|
      expected = ["tmux", "capture-pane", "-t", "%77", "-p"]
      raise "unexpected capture command: #{command.inspect}" unless command == expected

      ["other repo\n", "", status]
    end

    out, = capture_io { assert_equal 0, pane.run }
    assert_equal "other repo\n", out
  end

  def test_help_shows_follow_option
    pane = Harnex::Pane.new(["--help"])
    out, = capture_io { pane.run }
    assert_includes out, "--follow"
    assert_includes out, "--interval"
  end

  private

  def init_repo(path)
    system("git", "init", "-q", path, out: File::NULL, err: File::NULL)
  end

  def stub_tmux_system(pane, target)
    pane.define_singleton_method(:system) do |*args, **_kwargs|
      case args
      when ["tmux", "-V"], ["tmux", "has-session", "-t", target]
        true
      else
        raise "unexpected system call: #{args.inspect}"
      end
    end
  end

  def successful_status
    Object.new.tap do |status|
      status.define_singleton_method(:success?) { true }
    end
  end

  def write_registry(id, repo_root: @repo_root, pid: Process.pid, cli: "codex", tmux_target: nil, tmux_session: nil, tmux_window: nil)
    path = Harnex.registry_path(repo_root, id)
    payload = {
      "id" => id,
      "cli" => cli,
      "pid" => pid,
      "host" => "127.0.0.1",
      "port" => 43_500 + @paths.length,
      "repo_root" => repo_root,
      "started_at" => Time.now.iso8601
    }
    payload["tmux_target"] = tmux_target if tmux_target
    payload["tmux_session"] = tmux_session if tmux_session
    payload["tmux_window"] = tmux_window if tmux_window
    Harnex.write_registry(path, payload)
    @paths << path
    path
  end
end
