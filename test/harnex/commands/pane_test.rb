require_relative "../../test_helper"

class PaneCommandTest < Minitest::Test
  def setup
    @repo_root = Dir.mktmpdir("harnex-pane-repo")
    system("git", "init", "-q", @repo_root, out: File::NULL, err: File::NULL)
    @paths = []
  end

  def teardown
    @paths.each { |path| FileUtils.rm_f(path) }
    FileUtils.rm_rf(@repo_root)
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

  def test_returns_1_when_tmux_is_unavailable
    write_registry("pane-session")
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
    write_registry("pane-session")
    pane = Harnex::Pane.new(["--id", "pane-session", "--repo", @repo_root])
    pane.define_singleton_method(:system) do |*args, **_kwargs|
      case args
      when ["tmux", "-V"]
        true
      when ["tmux", "has-session", "-t", "pane-session"]
        false
      else
        raise "unexpected system call: #{args.inspect}"
      end
    end

    assert_output(nil, /not tmux-backed/) { assert_equal 1, pane.run }
  end

  def test_successful_capture_outputs_text
    write_registry("pane-session")
    pane = Harnex::Pane.new(["--id", "pane-session", "--repo", @repo_root])
    status = successful_status
    pane.define_singleton_method(:system) do |*args, **_kwargs|
      case args
      when ["tmux", "-V"], ["tmux", "has-session", "-t", "pane-session"]
        true
      else
        raise "unexpected system call: #{args.inspect}"
      end
    end
    pane.define_singleton_method(:capture_command) do |command|
      expected = ["tmux", "capture-pane", "-t", "pane-session", "-p"]
      raise "unexpected capture command: #{command.inspect}" unless command == expected

      ["prompt>\n", "", status]
    end

    out, = capture_io { assert_equal 0, pane.run }
    assert_equal "prompt>\n", out
  end

  def test_lines_flag_passes_start_offset_to_tmux_capture
    write_registry("pane-session")
    pane = Harnex::Pane.new(["--id", "pane-session", "--repo", @repo_root, "--lines", "20"])
    status = successful_status
    pane.define_singleton_method(:system) do |*args, **_kwargs|
      case args
      when ["tmux", "-V"], ["tmux", "has-session", "-t", "pane-session"]
        true
      else
        raise "unexpected system call: #{args.inspect}"
      end
    end

    captured_command = nil
    pane.define_singleton_method(:capture_command) do |command|
      captured_command = command
      ["tail\n", "", status]
    end

    capture_io { assert_equal 0, pane.run }
    assert_equal ["tmux", "capture-pane", "-t", "pane-session", "-p", "-S", "-20"], captured_command
  end

  def test_json_wraps_capture_with_metadata
    write_registry("pane-session")
    pane = Harnex::Pane.new(["--id", "pane-session", "--repo", @repo_root, "--json", "--lines", "5"])
    status = successful_status
    pane.define_singleton_method(:system) do |*args, **_kwargs|
      case args
      when ["tmux", "-V"], ["tmux", "has-session", "-t", "pane-session"]
        true
      else
        raise "unexpected system call: #{args.inspect}"
      end
    end
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
    write_registry("pane-session", pid: Process.pid)
    pane = Harnex::Pane.new(["--id", "pane-session", "--repo", @repo_root, "--follow", "--interval", "0"])
    status = successful_status

    stub_tmux_system(pane, "pane-session")

    call_count = 0
    pane.define_singleton_method(:capture_command) do |_command|
      call_count += 1
      ["screen #{call_count}\n", "", status]
    end

    # Stub alive_pid? to return false after 2 captures
    original_alive = Harnex.method(:alive_pid?)
    Harnex.define_singleton_method(:alive_pid?) do |pid|
      call_count >= 2 ? false : original_alive.call(pid)
    end

    out, = capture_io { assert_equal 0, pane.run }

    assert_operator call_count, :>=, 2
    # Last screen should be in output (clear codes + text)
    assert_includes out, "screen"
  ensure
    Harnex.define_singleton_method(:alive_pid?, &original_alive) if original_alive
  end

  def test_follow_only_redraws_on_change
    write_registry("pane-session", pid: Process.pid)
    pane = Harnex::Pane.new(["--id", "pane-session", "--repo", @repo_root, "--follow", "--interval", "0"])
    status = successful_status

    stub_tmux_system(pane, "pane-session")

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

    # 3 captures but only 1 clear+draw (first time)
    assert_equal 3, call_count
    assert_equal 1, out.scan("\e[H\e[2J").length
  ensure
    Harnex.define_singleton_method(:alive_pid?, &original_alive) if original_alive
  end

  def test_help_shows_follow_option
    pane = Harnex::Pane.new(["--help"])
    out, = capture_io { pane.run }
    assert_includes out, "--follow"
    assert_includes out, "--interval"
  end

  private

  def stub_tmux_system(pane, window)
    pane.define_singleton_method(:system) do |*args, **_kwargs|
      case args
      when ["tmux", "-V"], ["tmux", "has-session", "-t", window]
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

  def write_registry(id, pid: Process.pid, cli: "codex")
    path = Harnex.registry_path(@repo_root, id)
    Harnex.write_registry(path, {
      "id" => id,
      "cli" => cli,
      "pid" => pid,
      "host" => "127.0.0.1",
      "port" => 43_500 + @paths.length,
      "repo_root" => @repo_root,
      "started_at" => Time.now.iso8601
    })
    @paths << path
    path
  end
end
