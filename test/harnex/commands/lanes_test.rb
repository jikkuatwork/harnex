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

  def test_a_lane_merged_by_hand_is_tidied_by_the_next_harnex_call
    respond([done, 0, commit_work("hand.rb", "hand")], [done, 0])
    cli(Harnex::Delegate, ["--worktree", "byhand", "Add hand.rb"])
    cli(Harnex::Delegate, ["--worktree", "empty", "Do nothing"])
    git("merge", "--no-edit", "harnex/byhand")

    out = StringIO.new
    Harnex::LanesCommand.new([], out: out).run
    refute File.exist?(File.join(@repo, ".harnex", "worktrees", "byhand"))
    refute_includes git("branch"), "harnex/byhand"
    assert_equal "landed", Harnex::Lanes.resolve("byhand")["state"]
    assert File.directory?(File.join(@repo, ".harnex", "worktrees", "empty")), "a lane without commits is not merged work"
    assert_includes out.string, "empty"
  end

  def test_a_model_failure_suggests_retrying_on_pis_default_model
    pi_dir = File.join(@tmp, "pi-agent")
    FileUtils.mkdir_p(pi_dir)
    File.write(File.join(pi_dir, "settings.json"), JSON.generate("defaultProvider" => "foundry-zyt", "defaultModel" => "gpt-6.1-sol"))
    ENV["PI_CODING_AGENT_DIR"] = pi_dir
    respond([{ ok: false, turn_result: { ok: false, outcome_class: "failed", last_error: "API error (404): Model not found" } }, 1])
    code, out, = cli(Harnex::Delegate, ["--worktree", "badmodel", "--model", "foundry-zyt/gpt-9", "Task"])
    assert_equal 1, code
    assert_includes out, "FAILED"
    assert_includes out, "--model foundry-zyt/gpt-6.1-sol` (keeps the task; another model)"
  ensure
    ENV.delete("PI_CODING_AGENT_DIR")
  end

  def test_a_lane_without_commits_says_there_is_nothing_to_merge
    respond([done("Nothing needed changing."), 0])
    _code, out, = cli(Harnex::Delegate, ["--worktree", "noop", "Check things"])
    assert_includes out, "no commits to merge; `harnex land noop` removes the worktree"
    assert_equal 0, cli(Harnex::Land, ["noop"]).first
  end

  def test_closed_lanes_are_pruned_after_a_month_open_ones_never
    respond([done, 0], [done, 0])
    cli(Harnex::Delegate, ["--worktree", "old", "Old"])
    cli(Harnex::Delegate, ["--worktree", "stale-open", "Open"])
    cli(Harnex::Land, ["old"], discard: true)
    later = Time.now + 31 * 86_400
    Harnex::Lanes.prune_closed(now: later)
    assert_nil Harnex::Lanes.load(@repo, "old")
    refute_nil Harnex::Lanes.load(@repo, "stale-open"), "open lanes keep their record however old"
  end

  def test_land_without_names_lands_my_finished_lanes
    respond([done, 0, commit_work("one.rb", "1")], [done, 0, commit_work("two.rb", "2")])
    cli(Harnex::Delegate, ["--worktree", "first", "One"])
    cli(Harnex::Delegate, ["--worktree", "second", "Two"])
    code, out, = cli(Harnex::Land, [])
    assert_equal 0, code, out
    assert_includes out, "── first: merged"
    assert_includes out, "── second: merged"
    assert File.exist?(File.join(@repo, "two.rb"))
    _code, out, = cli(Harnex::Land, [])
    assert_includes out, "no finished worktree lanes to land"
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
    assert_nil Harnex::Lanes.load(@repo, "broken")
  end

  # #88: a repo phase allowlist refused every lane, and the refused lane's
  # record then blocked a retry under the same name.
  def test_lanes_tag_their_phase_and_a_refused_lane_frees_its_name
    File.write(@queue, JSON.generate([[nil, 2]]))
    code, _out, err = cli(Harnex::Delegate, ["--name", "b2-red", "Task"])
    assert_equal 1, code
    assert_includes err, "could not start lane b2-red"
    assert_nil Harnex::Lanes.load(@repo, "b2-red")
    refute File.exist?(Harnex::Lanes.brief_path(@repo, "b2-red"))

    respond([done, 0])
    assert_equal 0, cli(Harnex::Delegate, ["--name", "b2-red", "Task"]).first
    assert_equal "delegate", calls.last[calls.last.index("--phase") + 1]

    respond([done, 0])
    assert_equal 0, cli(Harnex::Delegate, ["--worktree", "impl", "--phase", "implement", "Task"]).first
    assert_equal "implement", calls.last[calls.last.index("--phase") + 1]
    respond([done("more"), 0])
    assert_equal 0, cli(Harnex::Reply, ["impl", "More"]).first
    assert_equal "implement", calls.last[calls.last.index("--phase") + 1]
  end

  def test_a_refused_reply_keeps_what_the_last_turn_left
    respond([done, 0])
    cli(Harnex::Delegate, ["--worktree", "kept", "Task"])
    before = Harnex::Lanes.resolve("kept")

    File.write(@queue, JSON.generate([[nil, 2]]))
    code, _out, err = cli(Harnex::Reply, ["kept", "More"])
    assert_equal 1, code
    assert_includes err, "could not start lane kept"
    lane = Harnex::Lanes.resolve("kept")
    assert_equal ["done", 1, before["launched_at"]], lane.values_at("state", "turns", "launched_at")
    assert_nil lane["last_error"]
  end

  def test_a_lane_older_harnex_kept_after_a_refused_start_frees_its_name
    Harnex::Lanes.save("name" => "stuck", "kind" => "delegate", "repo_root" => @repo, "run_root" => @repo,
                       "cwd" => @repo, "state" => "failed", "turns" => 0, "last_error" => "not allowlisted")
    respond([done, 0])
    code, out, = cli(Harnex::Delegate, ["--name", "stuck", "Task"])
    assert_equal 0, code
    assert_includes out, "── stuck: done"
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

  # #93: settlement and collection are separate in machine-readable output.
  def lane_json
    out = StringIO.new
    assert_equal 0, Harnex::LanesCommand.new(["--json"], out: out).run
    JSON.parse(out.string).to_h { |lane| [lane["name"], lane] }
  end

  def test_lanes_json_reports_settled_states_before_and_after_collection
    respond([{ ok: true, mode: "tmux" }, 0], [{ ok: true, mode: "tmux" }, 0])
    %w[success failure].each { |name| cli(Harnex::Delegate, ["--no-wait", "--name", name, "Task"]) }
    %w[success failure].each do |name|
      lane = Harnex::Lanes.resolve(name)
      event = { type: name == "success" ? "task_complete" : "task_failed", seq: 10,
                ts: Harnex::Lanes.now, outcome_class: name == "success" ? "completed_with_activity" : "policy_refusal",
                message: ("cyber_policy" if name == "failure") }
      File.write(Harnex.events_log_path(@repo, name), JSON.generate(event) + "\n")
    end

    rows = lane_json
    assert_equal ["done", false, false], rows["success"].values_at("state", "collected", "live")
    assert_equal ["failed", false, false], rows["failure"].values_at("state", "collected", "live")
    assert_equal "policy_refusal", rows["failure"]["outcome"]
    assert_equal "cyber_policy", rows["failure"]["last_error"]
    assert_equal %w[failure success], Harnex::Lanes.pending.map { |lane| lane["name"] }.sort,
                 "listing must not consume pending results"
    out = StringIO.new
    Harnex::LanesCommand.new([], out: out).run
    assert_equal 2, out.string.scan("finished, uncollected").length, "table wording stays unchanged"

    respond([{ ok: true, final_message: "Done" }, 0], [{ ok: false, last_error: "cyber_policy", outcome_class: "policy_refusal" }, 1])
    cli(Harnex::LaneResult, ["success"])
    cli(Harnex::LaneResult, ["failure"])
    rows = lane_json
    assert_equal ["done", true], rows["success"].values_at("state", "collected")
    assert_equal ["failed", true], rows["failure"].values_at("state", "collected")
    assert_empty Harnex::Lanes.pending
  end

  def test_lanes_json_does_not_confuse_a_live_settled_worker_with_running_work
    respond([{ ok: true, mode: "tmux" }, 0])
    cli(Harnex::Delegate, ["--no-wait", "--name", "idle", "Task"])
    Harnex.write_registry(Harnex.registry_path(@repo, "idle"), "id" => "idle", "pid" => Process.pid)
    File.write(Harnex.events_log_path(@repo, "idle"), JSON.generate(type: "task_failed", seq: 12,
               ts: Harnex::Lanes.now, outcome_class: "provider_error_unexplained") + "\n")
    assert_equal ["failed", false, true], lane_json["idle"].values_at("state", "collected", "live")
  ensure
    FileUtils.rm_f(Harnex.registry_path(@repo, "idle"))
  end

  def test_lanes_json_fences_previous_launches_and_follow_ups
    respond([{ ok: true, mode: "tmux" }, 0])
    cli(Harnex::Delegate, ["--no-wait", "--name", "fresh", "Task"])
    lane = Harnex::Lanes.resolve("fresh")
    lane.merge!("after_seq" => 20, "outcome" => "policy_refusal", "last_error" => "old refusal")
    Harnex::Lanes.save(lane)
    path = Harnex.events_log_path(@repo, "fresh")
    File.write(path, [
      { type: "task_failed", ts: "2000-01-01T00:00:00Z", seq: 30, outcome_class: "policy_refusal" },
      { type: "task_failed", ts: Harnex::Lanes.now, seq: 20, outcome_class: "policy_refusal" }
    ].map { |row| JSON.generate(row) }.join("\n") + "\n")
    assert_equal ["running", false], lane_json["fresh"].values_at("state", "collected")
    assert_nil lane_json["fresh"]["outcome"], "do not present the previous turn's failure as current"
    File.open(path, "a") { |f| f.puts JSON.generate(type: "task_complete", ts: Harnex::Lanes.now, seq: 21) }
    assert_equal "done", lane_json["fresh"]["state"]
    File.open(path, "a") { |f| f.puts JSON.generate(type: "work_turn", ts: Harnex::Lanes.now, seq: 22) }
    assert_equal "running", lane_json["fresh"]["state"], "a new turn supersedes an older settlement"
  end

  def test_lanes_json_reports_process_only_settlement_and_ignores_old_dispatch_rows
    respond([{ ok: true, mode: "tmux" }, 0])
    cli(Harnex::Delegate, ["--no-wait", "--name", "boot", "Task"])
    path = Harnex::DispatchHistory.path_for(@repo)
    row = { meta: { id: "boot", started_at: "2000-01-01T00:00:00Z", ended_at: "2000-01-01T00:00:01Z" },
            actual: { exit: "boot_failure", exit_code: 1 }, outcome: { class: "boot_failure" } }
    Harnex::DispatchHistory.append(path, row)
    assert_equal "running", lane_json["boot"]["state"]
    row[:meta][:ended_at] = Harnex::Lanes.now
    Harnex::DispatchHistory.append(path, row)
    assert_equal ["failed", false, "boot_failure"], lane_json["boot"].values_at("state", "collected", "outcome")
  end

  def test_lanes_json_reads_fresh_exit_status_before_the_dispatch_row_lands
    respond([{ ok: true, mode: "tmux" }, 0])
    cli(Harnex::Delegate, ["--no-wait", "--name", "exited", "Task"])
    path = Harnex.exit_status_path(@repo, "exited")
    Harnex.atomic_write_json(path, exit_code: 1, task_failed: true, exited_at: "2000-01-01T00:00:00Z",
                             outcome_class: "process_failed")
    assert_equal "running", lane_json["exited"]["state"]
    Harnex.atomic_write_json(path, exit_code: 1, task_failed: true, exited_at: Time.now.iso8601,
                             outcome_class: "provider_error_unexplained")
    assert_equal ["failed", false, "provider_error_unexplained"],
                 lane_json["exited"].values_at("state", "collected", "outcome")
  end

  def test_provider_failure_ask_footers_do_not_suggest_continuing_unchanged
    %w[policy_refusal provider_error_unexplained].each do |klass|
      respond([{ ok: false, turn_result: { outcome_class: klass, last_error: "provider error" } }, 1])
      code, out, err = cli(Harnex::Ask, ["--id", klass, "Question"])
      assert_equal 1, code
      assert_includes err, "next:"
      assert_includes err, klass == "policy_refusal" ? "rephrased brief or another route" : "provider/gateway logs before retrying"
      refute_includes out + err, "Continue the same task"
    end
  end

  def test_mcp_lanes_shows_a_settled_uncollected_worker_as_finished
    respond([{ ok: true, mode: "tmux" }, 0])
    cli(Harnex::Delegate, ["--no-wait", "--name", "mcp-failed", "Task"])
    File.write(Harnex.events_log_path(@repo, "mcp-failed"), JSON.generate(type: "task_failed", seq: 12,
               ts: Harnex::Lanes.now, outcome_class: "policy_refusal") + "\n")
    input = StringIO.new(JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/call",
                         params: { name: "lanes", arguments: { cwd: @repo } }) + "\n")
    output = StringIO.new
    Harnex::MCP::Server.new(input: input, output: output).run
    text = JSON.parse(output.string).dig("result", "content", 0, "text")
    # MCP keeps the human table (it carries each worker's live activity);
    # its row must still say the worker settled, never plain "working".
    row = text.lines.find { |line| line.start_with?("mcp-failed") }
    assert_includes row, "finished, uncollected"
  end

  def test_policy_refusal_footer_requires_a_rephrased_brief_or_another_route
    respond([{ ok: false, turn_result: { outcome_class: "policy_refusal", last_error: "provider cyber_policy refusal" } }, 1])
    code, out, = cli(Harnex::Delegate, ["--worktree", "refused", "Task"])
    assert_equal 1, code
    assert_includes out, "next: provider refused the content"
    assert_includes out, "rephrased brief or another route"
    refute_includes out, "Continue the same task"
    assert_includes out, "harnex discard refused"
  end

  def test_unexplained_provider_error_footer_requires_logs_before_retrying
    respond([{ ok: false, turn_result: { outcome_class: "provider_error_unexplained",
                last_error: "Unknown error (no error details in response)" } }, 1])
    code, out, = cli(Harnex::Delegate, ["--name", "unexplained", "Task"])
    assert_equal 1, code
    assert_includes out, "next: read the provider/gateway logs before retrying"
    refute_includes out, "Continue the same task"
  end

  def test_delegate_without_a_worktree_names_the_lane_from_the_task
    respond([done, 0])
    code, out, = cli(Harnex::Delegate, ["Run the slow bench please"])
    assert_equal 0, code
    assert_includes out, "── pi-slow-bench:"
    assert_includes out, "worked in place"
  end

  # ---- #89: one namespace per repo, names unique while in flight --------

  # holm-style layout: proj/.bare plus sibling worktrees, bare HEAD on main.
  def bare_layout(*siblings)
    base = File.join(@tmp, "proj")
    bare = File.join(base, ".bare")
    FileUtils.mkdir_p(base)
    git("clone", "-q", "--bare", @repo, bare, dir: @tmp)
    git("config", "user.name", "t", dir: bare)
    git("config", "user.email", "t@t", dir: bare)
    git("worktree", "add", "-q", File.join(base, "main"), "main", dir: bare)
    siblings.each { |name| git("worktree", "add", "-q", "-b", "night/#{name}", File.join(base, name), "main", dir: bare) }
    [File.realpath(File.join(base, "main")), *siblings.map { |name| File.realpath(File.join(base, name)) }]
  end

  def test_identical_briefs_in_sibling_worktrees_of_a_bare_repo_get_their_own_names
    main, *sides = bare_layout("night-s3", "night-an", "night-pg")
    Dir.chdir(main)
    brief = "You are a build lane in Holm's night queue. Read and carry out the brief at b.md"
    respond(*sides.map { [{ ok: true, mode: "tmux" }, 0] })
    names = sides.map do |side|
      _code, out, = cli(Harnex::Delegate, ["--no-wait", "--cwd", side, brief])
      out[/── (\S+): started/, 1]
    end
    assert_equal %w[pi-night-s3 pi-night-an pi-night-pg], names
    assert_equal [main], names.map { |name| Harnex::Lanes.resolve(name)["repo_root"] }.uniq, "one namespace: the bare repo's main worktree"

    out = StringIO.new
    Harnex::LanesCommand.new([], out: out).run
    names.each { |name| assert_includes out.string, name }

    respond([{ ok: true, final_message: "pi-night-an done" }, 0])
    code, out, = cli(Harnex::LaneResult, ["pi-night-an"])
    assert_equal 0, code, out
    assert_includes out, "pi-night-an done"
  end

  def test_identical_briefs_in_one_checkout_are_numbered
    respond([{ ok: true, mode: "tmux" }, 0], [{ ok: true, mode: "tmux" }, 0])
    brief = "You are a planning lane for Holm. Read and carry out the brief at plan.md"
    names = 2.times.map { cli(Harnex::Delegate, ["--no-wait", brief])[1][/── (\S+): started/, 1] }
    assert_equal %w[pi-planning-holm-read-plan pi-planning-holm-read-plan-2], names
  end

  # The eval that found it: unlanded lanes left in old eval repos refused
  # `worktree: slugify` everywhere. Only a running worker holds a chosen name.
  def test_a_name_whose_worker_runs_in_another_repo_is_refused_a_stale_one_is_not
    respond([done, 0], [{ ok: true, mode: "tmux" }, 0])
    cli(Harnex::Delegate, ["--worktree", "stale", "One"])
    cli(Harnex::Delegate, ["--no-wait", "--name", "busy", "Two"])
    Harnex.write_registry(Harnex.registry_path(@repo, "busy"), "id" => "busy", "pid" => Process.pid)
    other = File.join(@tmp, "other")
    FileUtils.mkdir_p(other)
    git("init", "-q", "-b", "main", dir: other)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init", dir: other)
    Dir.chdir(other)

    error = assert_raises(OptionParser::InvalidArgument) { cli(Harnex::Delegate, ["--name", "busy", "Three"]) }
    assert_includes error.message, "a worker named busy is working in #{@repo}"
    assert_equal @repo, Harnex::Lanes.resolve("busy")["repo_root"], "a working lane resolves from any repo"
    respond([done, 0])
    assert_equal 0, cli(Harnex::Delegate, ["--worktree", "stale", "Four"]).first, "an unlanded lane elsewhere does not hold its name"
    respond([{ ok: true, mode: "tmux" }, 0])
    _code, out, = cli(Harnex::Delegate, ["--no-wait", "Run the bench"])
    assert_includes out, "── pi-bench: started"
    respond([{ ok: true, mode: "tmux" }, 0])
    Dir.chdir(@repo)
    _code, out, = cli(Harnex::Delegate, ["--no-wait", "Run the bench"])
    assert_includes out, "── pi-bench-2: started", "generated names skip names in flight anywhere"
  ensure
    FileUtils.rm_f(Harnex.registry_path(@repo, "busy"))
  end

  def test_a_worktree_lane_cannot_start_inside_another_worktree
    main, side = bare_layout("night-x")
    Dir.chdir(main)
    error = assert_raises(OptionParser::InvalidArgument) { cli(Harnex::Delegate, ["--worktree", "w", "--cwd", side, "Task"]) }
    assert_includes error.message, "drop --worktree to work there in place"
  end

  # ---- #90: worktree lanes beside the main checkout ----------------------

  def test_config_puts_worktree_lanes_beside_the_checkout_and_land_honours_it
    FileUtils.mkdir_p(File.join(@repo, ".harnex"))
    File.write(File.join(@repo, ".harnex", "config.json"),
               JSON.generate("lanes" => { "worktree_path" => "../night-{name}", "branch" => "night/{mm}{dd}_{name}" }))
    respond([done, 0, commit_work("s3.rb", "s3")])
    code, out, = cli(Harnex::Delegate, ["--worktree", "s3", "Add s3.rb"])
    assert_equal 0, code, out

    worktree = File.join(@tmp, "night-s3")
    branch = "night/#{Time.now.strftime('%m%d')}_s3"
    assert_equal worktree, calls.last[calls.last.index("--cwd") + 1]
    assert_includes out, "worktree ../night-s3 (branch #{branch})"
    assert_includes File.read(calls.last[calls.last.index("--context-file") + 1]), "on branch #{branch}"

    code, out, = cli(Harnex::Land, ["s3"])
    assert_equal 0, code, out
    assert_includes out, "merged #{branch} into main (1 commit)"
    refute File.exist?(worktree)
    refute_includes git("branch"), branch
  end

  def test_bad_lane_templates_are_refused
    FileUtils.mkdir_p(File.join(@repo, ".harnex"))
    File.write(File.join(@repo, ".harnex", "config.json"), JSON.generate("lanes" => { "worktree_path" => "../fixed" }))
    error = assert_raises(OptionParser::InvalidArgument) { cli(Harnex::Delegate, ["--worktree", "w", "Task"]) }
    assert_includes error.message, "$.lanes.worktree_path must be a string containing {name}"
  end

  # ---- #91: a lane in place counts only its worker's commits -------------

  def worker_events(path, sha_command)
    future = "2999-01-01T00:00:00.000Z"
    "sha=$(#{sha_command}) && " \
      "printf '{\"type\":\"git\",\"phase\":\"start\",\"ts\":\"#{future}\",\"tracks_worker_commits\":true}\\n" \
      "{\"type\":\"worker_commits\",\"ts\":\"#{future}\",\"shas\":[\"%s\"]}\\n' $sha >> #{path}"
  end

  def test_an_in_place_lane_counts_its_own_commits_not_head_movement
    events = Harnex.events_log_path(@repo, "inplace")
    work = "#{commit_work('lib.rb', 'two')} && #{worker_events(events, 'git rev-parse HEAD')} && " \
           "#{commit_work('other.rb', 'theirs')}"
    respond([done, 0, work])
    _code, out, = cli(Harnex::Delegate, ["--name", "inplace", "Change lib.rb"])
    assert_includes out, "· 1 commit, 1 file (+1 -1) (HEAD also moved 1 commit by others)"
  end

  # ---- #92: interjections and the answers they replaced ------------------

  def test_messages_from_outside_the_lane_and_earlier_replies_are_reported
    future = "2999-01-01T00:00:00.000Z"
    events = Harnex.events_log_path(@repo, "review")
    File.write(events, [
      { type: "send", ts: future, msg: "[harnex session id=review] Review the plan" },
      { type: "send", ts: future, msg: "Also check section 2", from: { via: "reply" } },
      { type: "send", ts: future, msg: "Write it to /tmp/review.md instead", from: { via: "send" } }
    ].map { |row| JSON.generate(row) }.join("\n") + "\n")
    turn = { ok: true, final_message: "Understood; written there.", earlier_replies: ["Review: PASS (0 P1)."], model: "gpt-6.1-sol" }
    respond([{ ok: true, turn_result: turn }, 0])
    _code, out, = cli(Harnex::Delegate, ["--name", "review", "Review the plan"])

    assert_includes out, "[earlier reply this turn, before another message reached the worker]\nReview: PASS (0 P1)."
    assert_includes out, "[latest reply]\nUnderstood; written there."
    assert_includes out, "interjected: 1 message reached the worker from outside this lane"
    assert_includes out, "from a terminal (harnex send): \"Write it to /tmp/review.md instead\""
    refute_includes out, "Also check section 2", "the lane's own reply is not an interjection"
    refute_includes out, "Review the plan\"", "the launch prompt is not an interjection"
  end

end
