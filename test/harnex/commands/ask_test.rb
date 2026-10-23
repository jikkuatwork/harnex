require_relative "../../test_helper"
require "stringio"

class AskTest < Minitest::Test
  # A stand-in `harnex` that records its argv and prints a canned result.
  # results: one [result, exit_code] pair per launch, in order.
  def fake_harnex(dir, result, exit_code, results: nil)
    script = File.join(dir, "fake-harnex")
    queue = results || [[result, exit_code]]
    File.write(File.join(dir, "results.json"), JSON.generate(queue))
    File.write(script, <<~RUBY)
      calls = File.join(#{dir.inspect}, "calls.json")
      log = File.exist?(calls) ? JSON.parse(File.read(calls)) : []
      log << ARGV
      File.write(calls, log.to_json)
      File.write(#{File.join(dir, 'argv.json').inspect}, ARGV.to_json)
      result, code = JSON.parse(File.read(#{File.join(dir, 'results.json').inspect})).fetch(log.length - 1)
      puts result.to_json
      exit code
    RUBY
    [Gem.ruby, "-rjson", script]
  end

  def ask(argv, result, exit_code)
    Dir.mktmpdir do |dir|
      out = StringIO.new
      err = StringIO.new
      code = Harnex::Ask.new(argv, out: out, err: err, harnex_command: fake_harnex(dir, result, exit_code)).run
      yield code, out.string, err.string, JSON.parse(File.read(File.join(dir, "argv.json")))
    end
  end

  def test_prints_the_answer_and_runs_read_only_by_default
    result = { ok: true, id: "pi-ask-1", turn_result: { final_message: "It lives in dispatch_history.rb." } }
    ask(["Where", "are", "rows", "written?"], result, 0) do |code, out, _err, argv|
      assert_equal 0, code
      assert_equal "It lives in dispatch_history.rb.\n", out
      assert_equal "Where are rows written?", argv.fetch(argv.index("--context") + 1)
      assert_includes argv, "--wait-done"
      assert_includes argv, "--auto-stop"
      assert_equal %w[--no-approve --tools read,grep,find,ls], argv.drop(argv.index("--"))[1..]
    end
  end

  def test_write_mode_and_file_questions
    ask(["--write", "--file", "/tmp/q.md", "--section", "Task", "--model", "foundry-zyt/gpt-6.1-sol", "--timeout", "9m"],
        { ok: true, turn_result: { final_message: "done" } }, 0) do |_code, _out, _err, argv|
      refute_includes argv, "--tools"
      assert_equal "/tmp/q.md", argv.fetch(argv.index("--context-file") + 1)
      assert_equal "Task", argv.fetch(argv.index("--context-section") + 1)
      assert_equal "540.0", argv.fetch(argv.index("--wait-timeout") + 1)
      assert_equal "foundry-zyt/gpt-6.1-sol", argv.fetch(argv.index("--model") + 1)
    end
  end

  def test_timeout_and_failure_explain_themselves_on_stderr
    timeout = { ok: false, id: "pi-ask-2", wait_result: "timeout", resume: "harnex wait --id pi-ask-2 --until done" }
    ask(["slow question"], timeout, 124) do |code, out, err, _argv|
      assert_equal [124, ""], [code, out]
      assert_includes err, "keep waiting with: #{Harnex.cli_command} result pi-ask-2"
    end
    failed = { ok: false, id: "pi-ask-3", turn_result: { last_error: "high demand", outcome_class: "provider_capacity" } }
    ask(["q"], failed, 1) do |code, _out, err, _argv|
      assert_equal 1, code
      assert_includes err, "high demand"
    end
  end

  def test_read_only_asks_record_outside_the_repo_and_summarize_on_stderr
    result = { ok: true, id: "pi-ask-9", turn_result: { final_message: "yes", model: "gpt-6.1-sol" } }
    ask(["q"], result, 0) do |_code, _out, err, argv|
      assert_equal File.join(Harnex::STATE_DIR, "ask"), argv.fetch(argv.index("--root") + 1)
      assert_equal File.expand_path(Dir.pwd), argv.fetch(argv.index("--cwd") + 1)
      assert_match(/pi-ask-9 answered in \d+s \(model gpt-6.1-sol\)/, err)
    end
    ask(["--write", "q"], result, 0) do |_code, _out, _err, argv|
      refute_includes argv, "--root", "work that edits the repo records in the repo"
    end
  end

  def test_fallback_model_answers_after_provider_capacity
    Dir.mktmpdir do |dir|
      capacity = { ok: false, id: "pi-ask-a", turn_result: { outcome_class: "provider_capacity", last_error: "rate limit" } }
      answered = { ok: true, id: "pi-ask-b", turn_result: { final_message: "from sol" } }
      command = fake_harnex(dir, nil, nil, results: [[capacity, 1], [answered, 0]])
      out = StringIO.new
      err = StringIO.new
      code = Harnex::Ask.new(["--model", "foundry-zyt/gpt-6-luna", "--fallback-model", "foundry-zyt/gpt-6-sol", "q"],
                             out: out, err: err, harnex_command: command).run
      calls = JSON.parse(File.read(File.join(dir, "calls.json")))

      assert_equal [0, "from sol\n"], [code, out.string]
      assert_equal %w[foundry-zyt/gpt-6-luna foundry-zyt/gpt-6-sol], calls.map { |argv| argv.fetch(argv.index("--model") + 1) }
      assert_includes err.string, "hit provider capacity"
    end
  end

  def test_resume_keeps_waiting_on_the_lane_and_prints_the_answer
    Dir.mktmpdir do |dir|
      full = File.join(dir, "final.md")
      File.write(full, "the whole answer\n")
      timeout = { ok: false, id: "pi-ask-r1", wait_result: "timeout", turn_result: { wait_result: "timeout" } }
      done = { ok: true, id: "pi-ask-r1", wait_result: "done", model: "gpt-6.1-sol",
               final_message: "the whole", final_message_truncated: true, final_message_path: full }
      command = fake_harnex(dir, nil, nil, results: [[timeout, 124], [done, 0]])
      err = StringIO.new
      first = Harnex::Ask.new(["--id", "pi-ask-r1", "slow question"], out: StringIO.new, err: err, harnex_command: command).run
      assert_equal 124, first
      assert_equal "running", Harnex::Lanes.resolve("pi-ask-r1")["state"]

      out = StringIO.new
      code = Harnex::Ask.new(["--resume", "pi-ask-r1"], out: out, err: StringIO.new, harnex_command: command).run
      wait = JSON.parse(File.read(File.join(dir, "calls.json"))).last
      assert_equal [0, "the whole answer\n"], [code, out.string]
      assert_equal %w[wait --id pi-ask-r1 --repo], wait.first(4)
      assert_includes wait, "--since"
      assert_equal "done", Harnex::Lanes.resolve("pi-ask-r1")["state"]
    end
  end

  # #88: asks tag their run's phase; one refused before it started leaves no lane.
  def test_asks_tag_their_phase_and_a_refused_ask_leaves_no_lane
    ask(["--id", "pi-ask-p1", "q"], { ok: true, turn_result: { final_message: "a" } }, 0) do |_code, _out, _err, argv|
      assert_equal "ask", argv.fetch(argv.index("--phase") + 1)
    end
    ask(["--write", "--phase", "code-review", "q"], { ok: true, turn_result: { final_message: "a" } }, 0) do |_code, _out, _err, argv|
      assert_equal "code-review", argv.fetch(argv.index("--phase") + 1)
    end
    ask(["--write", "--id", "pi-ask-refused", "q"], {}, 2) do |code, _out, _err, _argv|
      assert_equal 2, code
      assert_raises(OptionParser::InvalidArgument) { Harnex::Lanes.resolve("pi-ask-refused") }
    end
  end

  def test_resume_of_a_pre_lane_ask_uses_its_repo
    ask(["--resume", "pi-ask-old", "--repo", "/tmp/r"], { ok: true, final_message: "old" }, 0) do |code, out, _err, argv|
      assert_equal [0, "old\n"], [code, out]
      assert_equal %w[wait --id pi-ask-old --repo /tmp/r --until done], argv.last(9).first(7)
    end
  end

  def test_usage_errors
    assert_raises(OptionParser::MissingArgument) { Harnex::Ask.new([]).run }
    assert_raises(OptionParser::InvalidOption) { Harnex::Ask.new(["--section", "x", "q"]).run }
    assert_raises(OptionParser::InvalidOption) { Harnex::Ask.new(["--bogus", "q"]).run }
    assert_raises(OptionParser::InvalidArgument) { Harnex::Ask.new(["--resume", "pi-ask-unknown"]).run }
    assert_raises(OptionParser::InvalidOption) { Harnex::Ask.new(["--resume", "pi-ask-1", "--repo", "/r", "q"]).run }
    assert_raises(OptionParser::InvalidOption) { Harnex::Ask.new(["--repo", "/r", "q"]).run }
  end
end
