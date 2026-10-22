require_relative "../../test_helper"
require "stringio"

# #87 lane verbs against real git repos. A fake `harnex` stands in for the
# low-level CLI: it logs argv, may act as the worker (a shell snippet run in
# the lane's --cwd), and prints a canned result.
class LanesTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("harnex-lanes")
    @repo = File.join(@tmp, "repo")
    FileUtils.mkdir_p(@repo)
    git("init", "-q", "-b", "main")
    git("config", "user.name", "t")
    git("config", "user.email", "t@t")
    File.write(File.join(@repo, "lib.rb"), "one\n")
    git("add", "-A")
    git("commit", "-qm", "init")
    @calls = File.join(@tmp, "calls.json")
    @queue = File.join(@tmp, "queue.json")
    @script = File.join(@tmp, "fake-harnex")
    File.write(@script, <<~RUBY)
      require "json"
      lock = File.open(#{@queue.inspect} + ".lock", File::RDWR | File::CREAT)
      lock.flock(File::LOCK_EX)
      log = File.exist?(#{@calls.inspect}) ? JSON.parse(File.read(#{@calls.inspect})) : []
      log << ARGV
      File.write(#{@calls.inspect}, log.to_json)
      queue = JSON.parse(File.read(#{@queue.inspect}))
      result, code, work = queue.shift
      File.write(#{@queue.inspect}, queue.to_json)
      lock.flock(File::LOCK_UN)
      cwd = ARGV[ARGV.index("--cwd") + 1] if ARGV.include?("--cwd")
      system("sh", "-c", work, chdir: cwd) if work && cwd
      puts result.to_json
      exit code
    RUBY
    @command = [Gem.ruby, @script]
    @pwd = Dir.pwd
    Dir.chdir(@repo)
  end

  def teardown
    Dir.chdir(@pwd)
    FileUtils.rm_rf(@tmp)
  end

  def git(*args, dir: @repo)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    assert status.success?, "git #{args.join(' ')}: #{out}"
    out
  end

  def respond(*entries)
    File.write(@queue, JSON.generate(entries))
  end

  def calls
    JSON.parse(File.read(@calls))
  end

  def cli(klass, argv, **kw)
    out = StringIO.new
    err = StringIO.new
    code = klass.new(argv, out: out, err: err, harnex_command: @command, **kw).run
    [code, out.string, err.string]
  end

  def done(message = "Added it; tests pass.")
    { ok: true, turn_result: { ok: true, final_message: message, model: "gpt-6.1-sol" } }
  end

  def commit_work(file, text)
    "printf '#{text}\\n' > #{file} && git add -A && git commit -qm 'work on #{file}'"
  end

  def test_delegate_in_a_worktree_prints_the_reply_and_what_to_do_next
    respond([done, 0, commit_work("lib.rb", "two")])
    code, out, = cli(Harnex::Delegate, ["--worktree", "wc", "Add word count"])

    assert_equal 0, code
    worktree = File.join(@repo, ".harnex", "worktrees", "wc")
    assert_includes out, "Added it; tests pass."
    assert_match(/── wc: done in \d+s · gpt-6\.1-sol · 1 commit, 1 file \(\+1 -1\)/, out)
    assert_includes out, "harnex land wc"
    run = calls.first
    assert_equal %w[run pi --id wc --tmux wc], run.first(6)
    assert_equal worktree, run[run.index("--cwd") + 1]
    assert_equal @repo, run[run.index("--root") + 1]
    assert_includes run, "--auto-stop"
    brief = File.read(run[run.index("--context-file") + 1])
    assert_includes brief, "Add word count"
    assert_includes brief, "commit your changes on this branch"
    assert_includes File.read(File.join(@repo, ".git", "info", "exclude")), ".harnex/"
    assert_empty git("status", "--porcelain")
    assert_equal "done", Harnex::Lanes.resolve("wc")["state"]
  end

  def test_parallel_lanes_then_result_collects_everything_once
    respond([{ ok: true, id: "a", mode: "tmux" }, 0], [{ ok: true, id: "b", mode: "tmux" }, 0])
    assert_equal 0, cli(Harnex::Delegate, ["--no-wait", "--worktree", "a", "Task A"]).first
    code, out, = cli(Harnex::Delegate, ["--no-wait", "--worktree", "b", "Task B"])
    assert_equal 0, code
    assert_includes out, "collect: harnex result b"
    refute calls.last.include?("--wait-done")

    respond([{ ok: true, final_message: "A done" }, 0], [{ ok: true, final_message: "B done" }, 0])
    code, out, = cli(Harnex::LaneResult, [])
    assert_equal 0, code
    assert_includes out, "A done"
    assert_includes out, "B done"
    waits = calls.last(2)
    assert(waits.all? { |argv| argv.first == "wait" && argv.include?("--since") })

    _code, out, = cli(Harnex::LaneResult, [])
    assert_includes out, "no lanes waiting"
  end

  def test_a_long_delegate_says_how_to_keep_waiting
    respond([{ ok: false, turn_result: { wait_result: "timeout" } }, 124])
    code, out, = cli(Harnex::Delegate, ["--worktree", "slow", "--timeout", "2s", "Slow task"])
    assert_equal 124, code
    assert_match(/── slow: still working \(\d+s so far\)/, out)
    assert_includes out, "keep waiting: harnex result slow"
    assert_equal "2.0", calls.first[calls.first.index("--wait-timeout") + 1]

    respond([{ ok: true, final_message: "finally" }, 0])
    code, out, = cli(Harnex::LaneResult, ["slow"])
    assert_equal 0, code
    assert_includes out, "finally"
  end

  def test_land_merges_and_cleans_up
    respond([done, 0, commit_work("new.rb", "new")])
    cli(Harnex::Delegate, ["--worktree", "feat", "Add new.rb"])
    code, out, = cli(Harnex::Land, ["feat"])

    assert_equal 0, code, out
    assert_includes out, "merged harnex/feat into main (1 commit)"
    assert File.exist?(File.join(@repo, "new.rb"))
    refute File.exist?(File.join(@repo, ".harnex", "worktrees", "feat"))
    refute_includes git("branch"), "harnex/feat"
    assert_empty git("status", "--porcelain")
    assert_equal "landed", Harnex::Lanes.resolve("feat")["state"]
  end

  def test_land_commits_leftover_changes_first
    respond([done, 0, "printf 'left\\n' > left.rb"])
    cli(Harnex::Delegate, ["--worktree", "leftover", "Write left.rb"])
    code, out, = cli(Harnex::Land, ["leftover"])
    assert_equal 0, code, out
    assert_includes out, "committed its uncommitted changes first"
    assert File.exist?(File.join(@repo, "left.rb"))
  end

  def test_land_conflict_leaves_the_merge_for_the_caller_then_cleans_up
    respond([done, 0, commit_work("lib.rb", "from-a")], [done, 0, commit_work("lib.rb", "from-b")])
    cli(Harnex::Delegate, ["--worktree", "a", "A"])
    cli(Harnex::Delegate, ["--worktree", "b", "B"])
    assert_equal 0, cli(Harnex::Land, ["a"]).first

    code, out, = cli(Harnex::Land, ["b"])
    assert_equal 1, code
    assert_includes out, "merge conflict in lib.rb"
    assert File.directory?(File.join(@repo, ".harnex", "worktrees", "b")), "the lane is kept until the merge finishes"

    code, out, = cli(Harnex::Land, ["b"])
    assert_equal 1, code
    assert_includes out, "a merge is in progress"

    File.write(File.join(@repo, "lib.rb"), "from-a\nfrom-b\n")
    git("add", "lib.rb")
    git("commit", "-qm", "merge b")
    code, out, = cli(Harnex::Land, ["b"])
    assert_equal 0, code, out
    assert_includes out, "was already merged"
    refute File.exist?(File.join(@repo, ".harnex", "worktrees", "b"))
  end

  def test_discard_drops_the_worktree_and_branch
    respond([done, 0, commit_work("x.rb", "x")])
    cli(Harnex::Delegate, ["--worktree", "nope", "X"])
    code, out, = cli(Harnex::Land, ["nope"], discard: true)
    assert_equal 0, code
    assert_includes out, "discarded"
    refute_includes git("branch"), "harnex/nope"
    refute File.exist?(File.join(@repo, "x.rb"))
  end

  def test_reply_to_a_finished_lane_resumes_its_pi_session
    respond([done, 0])
    cli(Harnex::Delegate, ["--worktree", "wc", "Add word count"])
    lane = Harnex::Lanes.resolve("wc")
    lane["agent_session_id"] = "sess-123"
    Harnex::Lanes.save(lane)

    respond([done("Also added char_count."), 0])
    code, out, = cli(Harnex::Reply, ["wc", "Also add char_count"])
    assert_equal 0, code
    assert_includes out, "Also added char_count."
    run = calls.last
    assert_equal "Also add char_count", run[run.index("--context") + 1]
    assert_equal %w[--session sess-123], run.drop(run.index("--") + 1)
    assert_equal 2, Harnex::Lanes.resolve("wc")["turns"]
  end

  def test_reply_to_a_working_lane_is_a_follow_up
    respond([{ ok: true, id: "busy", mode: "tmux" }, 0])
    cli(Harnex::Delegate, ["--no-wait", "--worktree", "busy", "Long task"])
    lane = Harnex::Lanes.resolve("busy")
    Harnex.write_registry(Harnex.registry_path(lane["run_root"], "busy"), "id" => "busy", "pid" => Process.pid)

    respond([{ ok: true, after_seq: 41, final_message: "Took the follow-up." }, 0])
    code, out, = cli(Harnex::Reply, ["busy", "Also cover the empty case"])
    assert_equal 0, code
    assert_includes out, "Took the follow-up."
    assert_equal %w[send --id busy --repo], calls.last.first(4)
    assert_equal 41, Harnex::Lanes.resolve("busy")["after_seq"]
  ensure
    FileUtils.rm_f(Harnex.registry_path(@repo, "busy"))
  end

  def test_a_lane_that_cannot_start_leaves_nothing_behind
    File.write(@queue, JSON.generate([[nil, 2]]))
    code, _out, err = cli(Harnex::Delegate, ["--worktree", "broken", "Task"])
    assert_equal 1, code
    assert_includes err, "could not start lane broken"
    refute File.exist?(File.join(@repo, ".harnex", "worktrees", "broken"))
    refute_includes git("branch"), "harnex/broken"
  end

  def test_names_must_be_free
    respond([done, 0])
    cli(Harnex::Delegate, ["--worktree", "dup", "One"])
    error = assert_raises(OptionParser::InvalidArgument) { cli(Harnex::Delegate, ["--worktree", "dup", "Two"]) }
    assert_includes error.message, "harnex reply dup"
    assert_raises(OptionParser::InvalidArgument) { cli(Harnex::Delegate, ["--worktree", "bad name", "x"]) }
  end

  def test_low_level_habits_are_accepted
    respond([done, 0])
    code, = cli(Harnex::Delegate, ["--id", "habit", "--tmux", "habit", "--auto-stop", "--wait-done", "--wait-timeout", "5m",
                                   "--context", "Do the thing"])
    assert_equal 0, code
    run = calls.last
    assert_equal %w[run pi --id habit --tmux habit], run.first(6)
    assert_equal "300.0", run[run.index("--wait-timeout") + 1]
    assert_includes File.read(run[run.index("--context-file") + 1]), "Do the thing"

    respond([done("again"), 0])
    code, out, = cli(Harnex::Reply, ["--message", "More", "--id", "habit", "--wait-done"])
    assert_equal 0, code
    assert_includes out, "again"
    assert_equal "More", calls.last[calls.last.index("--context") + 1]
  end

  def test_lanes_lists_what_each_needs_next
    respond([done, 0, commit_work("y.rb", "y")])
    cli(Harnex::Delegate, ["--worktree", "ylane", "Y"])
    out = StringIO.new
    assert_equal 0, Harnex::LanesCommand.new([], out: out).run
    assert_match(/ylane\s+done/, out.string)
    assert_includes out.string, "harnex land ylane"
  end

  def test_delegate_without_a_worktree_names_the_lane_from_the_task
    respond([done, 0])
    code, out, = cli(Harnex::Delegate, ["Run the slow bench please"])
    assert_equal 0, code
    assert_includes out, "── pi-run-the-slow-bench:"
    assert_includes out, "worked in place"
  end
end
