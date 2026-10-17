require_relative "../../test_helper"

class WaiterTest < Minitest::Test
  # --- help ---

  def test_help_returns_zero
    waiter = Harnex::Waiter.new(["--help"])
    assert_output(/Usage:/) { assert_equal 0, waiter.run }
  end

  def test_help_mentions_until
    waiter = Harnex::Waiter.new(["--help"])
    assert_output(/--until STATE/) { waiter.run }
  end

  # --- requires --id ---

  def test_raises_without_id
    waiter = Harnex::Waiter.new([])
    assert_raises(RuntimeError) { waiter.run }
  end

  # --- no session found (wait-until-exit) ---

  def test_returns_unknown_when_no_session_or_terminal_summary_exists
    waiter = Harnex::Waiter.new(["--id", "nonexistent"])
    out, err = capture_io { assert_equal 1, waiter.run }
    assert_match(/no session found/, err)

    payload = JSON.parse(out)
    refute payload["ok"]
    assert_equal "unknown", payload["state"]
    assert_equal false, payload["terminal"]
  end

  # --- no session found (wait-until-state) ---

  def test_until_prompt_returns_1_when_no_session
    waiter = Harnex::Waiter.new(["--id", "nonexistent", "--until", "prompt"])
    assert_output(nil, /no session found/) { assert_equal 1, waiter.run }
  end

  def test_wait_until_done_reads_successful_terminal_summary_without_task_complete
    Dir.mktmpdir("harnex-wait-done-summary") do |repo|
      system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      dispatch_path = File.join(repo, ".harnex", "dispatch.jsonl")
      FileUtils.mkdir_p(File.dirname(dispatch_path))
      File.write(dispatch_path, JSON.generate({
        "meta" => {
          "id" => "done-summary",
          "repo" => repo,
          "started_at" => Time.now.iso8601,
          "ended_at" => Time.now.iso8601
        },
        "actual" => {
          "task_complete" => false,
          "exit" => "success",
          "exit_code" => 0
        },
        "predicted" => {}
      }) + "\n")

      waiter = Harnex::Waiter.new(["--repo", repo, "--id", "done-summary", "--until", "done"])
      out, = capture_io { assert_equal 0, waiter.run }
      payload = JSON.parse(out)
      assert payload["ok"]
      assert_equal true, payload["done"]
      assert_equal "completed", payload["work_state"]
      assert_equal "completed", payload["state"]
      assert_equal "exited", payload["process_state"]
      assert_equal true, payload["terminal"]
      assert_equal "done", payload["status"]
    end
  end

  def test_wait_until_done_returns_nonzero_for_failed_terminal_summary
    Dir.mktmpdir("harnex-wait-done-failed-summary") do |repo|
      system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      dispatch_path = File.join(repo, ".harnex", "dispatch.jsonl")
      FileUtils.mkdir_p(File.dirname(dispatch_path))
      File.write(dispatch_path, JSON.generate({
        "meta" => {
          "id" => "failed-summary",
          "repo" => repo,
          "started_at" => Time.now.iso8601,
          "ended_at" => Time.now.iso8601
        },
        "actual" => {
          "task_complete" => false,
          "exit" => "failure",
          "exit_code" => 7
        },
        "predicted" => {}
      }) + "\n")

      waiter = Harnex::Waiter.new(["--repo", repo, "--id", "failed-summary", "--until", "done"])
      out, = capture_io { assert_equal 1, waiter.run }
      payload = JSON.parse(out)
      refute payload["ok"]
      assert_equal false, payload["done"]
      assert_equal "failed", payload["work_state"]
      assert_equal "failed", payload["state"]
      assert_equal "exited", payload["process_state"]
      assert_equal true, payload["terminal"]
      assert_equal "failed", payload["wait_result"]
      assert_equal 7, payload["exit_code"]
    end
  end

  def test_wait_until_done_resolves_from_unified_v2_end_row
    Dir.mktmpdir("harnex-wait-v2-row") do |repo|
      system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      dispatch_path = File.join(repo, ".harnex", "dispatch.jsonl")
      FileUtils.mkdir_p(File.dirname(dispatch_path))
      File.write(dispatch_path, JSON.generate({
        "schema_version" => 2,
        "record_type" => "dispatch_end",
        "id" => "v2-done",
        "session_id" => "sess-v2-done",
        "cli" => "codex",
        "status" => "completed",
        "terminal_event" => "task_complete",
        "started_at" => Time.now.iso8601,
        "ended_at" => Time.now.iso8601,
        "meta" => {
          "id" => "v2-done",
          "repo" => repo,
          "started_at" => Time.now.iso8601,
          "ended_at" => Time.now.iso8601
        },
        "predicted" => {},
        "actual" => {
          "task_complete" => true,
          "exit" => "success",
          "exit_code" => 0
        },
        "outcome" => { "class" => "completed_with_proof", "report_status" => nil }
      }) + "\n")

      waiter = Harnex::Waiter.new(["--repo", repo, "--id", "v2-done", "--until", "done"])
      out, = capture_io { assert_equal 0, waiter.run }
      payload = JSON.parse(out)
      assert payload["ok"]
      assert_equal true, payload["done"]
      assert_equal true, payload["task_complete"]
      assert_equal "completed", payload["state"]
      assert_equal "completed_with_proof", payload["outcome_class"]
      assert_equal "dispatch_end", payload["source"]
      refute payload.key?("summary_out"), "removed mirror key must not reappear"
    end
  end

  def test_wait_until_exit_reads_terminal_summary_when_exit_file_is_missing
    Dir.mktmpdir("harnex-wait-summary") do |repo|
      system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      dispatch_path = File.join(repo, ".harnex", "dispatch.jsonl")
      FileUtils.mkdir_p(File.dirname(dispatch_path))
      File.write(dispatch_path, JSON.generate({
        "meta" => {
          "id" => "summary-only",
          "repo" => repo,
          "started_at" => Time.now.iso8601,
          "ended_at" => Time.now.iso8601
        },
        "actual" => {
          "task_complete" => true,
          "exit" => "success",
          "exit_code" => 0
        },
        "predicted" => {}
      }) + "\n")

      waiter = Harnex::Waiter.new(["--repo", repo, "--id", "summary-only"])
      out, = capture_io { assert_equal 0, waiter.run }
      payload = JSON.parse(out)
      assert payload["ok"]
      assert_equal "completed", payload["state"]
      assert_equal true, payload["terminal"]
      assert_equal "success", payload["exit"]
      assert_equal 0, payload["exit_code"]
      assert_equal "dispatch_end", payload["source"]
    end
  end

  # --- wait-until-exit reads exit status file ---

  def test_reads_exit_status_file_when_session_gone
    repo_root = Dir.pwd
    id = "exited-worker-#{$$}"
    exit_path = Harnex.exit_status_path(repo_root, id)

    File.write(exit_path, JSON.generate(ok: true, id: id, exit_code: 0, status: "exited"))

    waiter = Harnex::Waiter.new(["--id", id])
    out, = capture_io { assert_equal 0, waiter.run }
    data = JSON.parse(out)
    assert_equal id, data["id"]
  ensure
    FileUtils.rm_f(exit_path) if exit_path
  end

  def test_reads_signal_metadata_from_exit_status_file
    repo_root = Dir.pwd
    id = "signaled-worker-#{$$}"
    exit_path = Harnex.exit_status_path(repo_root, id)

    File.write(exit_path, JSON.generate(ok: true, id: id, exit_code: 143, signal: 15, status: "exited"))

    waiter = Harnex::Waiter.new(["--id", id])
    out, = capture_io { assert_equal 143, waiter.run }
    data = JSON.parse(out)
    assert_equal 143, data["exit_code"]
    assert_equal 15, data["signal"]
  ensure
    FileUtils.rm_f(exit_path) if exit_path
  end

  # --- wait-until-state with immediate prompt ---

  def test_until_prompt_succeeds_when_api_returns_prompt
    repo_root = Dir.pwd
    id = "prompt-worker-#{$$}"
    token = SecureRandom.hex(16)

    # Start a fake HTTP server that always returns agent_state: "prompt"
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    server_thread = Thread.new do
      loop do
        client = server.accept
        client.gets("\r\n") # request line
        while (line = client.gets("\r\n"))
          break if line.strip.empty?
        end
        body = JSON.generate(agent_state: "prompt", ok: true)
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      rescue IOError, Errno::EBADF
        break
      end
    end

    # Write a registry entry pointing at our fake server
    registry_path = Harnex.registry_path(repo_root, id)
    Harnex.write_registry(registry_path, {
      "id" => id,
      "pid" => Process.pid, # our own pid, guaranteed alive
      "host" => "127.0.0.1",
      "port" => port,
      "token" => token,
      "repo_root" => repo_root
    })

    waiter = Harnex::Waiter.new(["--id", id, "--until", "prompt"])
    out, err = capture_io { assert_equal 0, waiter.run }
    data = JSON.parse(out)
    assert data["ok"]
    assert_equal "prompt", data["state"]
    assert_equal id, data["id"]
    assert data.key?("waited_seconds")
    assert_match(/waiting for.*prompt/, err)
  ensure
    server&.close
    server_thread&.join(1)
    FileUtils.rm_f(registry_path) if registry_path
  end

  # --- wait-until-state timeout ---

  def test_until_prompt_times_out
    repo_root = Dir.pwd
    id = "timeout-worker-#{$$}"
    token = SecureRandom.hex(16)

    # Fake server that always returns agent_state: "busy"
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    server_thread = Thread.new do
      loop do
        client = server.accept
        client.gets("\r\n")
        while (line = client.gets("\r\n"))
          break if line.strip.empty?
        end
        body = JSON.generate(agent_state: "busy", ok: true)
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      rescue IOError, Errno::EBADF
        break
      end
    end

    registry_path = Harnex.registry_path(repo_root, id)
    Harnex.write_registry(registry_path, {
      "id" => id,
      "pid" => Process.pid,
      "host" => "127.0.0.1",
      "port" => port,
      "token" => token,
      "repo_root" => repo_root
    })

    waiter = Harnex::Waiter.new(["--id", id, "--until", "prompt", "--timeout", "0.1"])
    out, = capture_io { assert_equal 124, waiter.run }
    data = JSON.parse(out)
    refute data["ok"]
    assert_equal "timeout", data["status"]
    assert_equal "busy", data["state"]
  ensure
    server&.close
    server_thread&.join(1)
    FileUtils.rm_f(registry_path) if registry_path
  end

  # --- wait --until done exit-code contract (issue #62) ---

  def test_wait_until_done_returns_3_when_no_signal_exists_at_all
    Dir.mktmpdir("harnex-wait-no-session") do |repo|
      system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)

      waiter = Harnex::Waiter.new(["--repo", repo, "--id", "never-existed", "--until", "done"])
      out, err = capture_io { assert_equal 3, waiter.run }
      assert_match(/no session found/, err)

      payload = JSON.parse(out)
      refute payload["ok"]
      assert_equal "no_such_session", payload["status"]
      assert_equal "no_such_session", payload["wait_result"]
    end
  end

  def test_wait_until_done_returns_2_for_rejected_proof_exit_status
    Dir.mktmpdir("harnex-wait-rejected") do |repo|
      system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      id = "rejected-proof-worker"
      exit_path = Harnex.exit_status_path(repo, id)
      File.write(exit_path, JSON.generate(
        ok: false, id: id, exit_code: 3, state: "failed",
        task_complete: false, task_failed: true,
        outcome_class: "report_rejected", artifact_report_status: "rejected",
        exited_at: Time.now.iso8601
      ))

      waiter = Harnex::Waiter.new(["--repo", repo, "--id", id, "--until", "done"])
      out, = capture_io { assert_equal 2, waiter.run }

      payload = JSON.parse(out)
      refute payload["ok"]
      assert_equal "rejected_proof", payload["wait_result"]
      assert_equal "report_rejected", payload["outcome_class"]
    ensure
      FileUtils.rm_f(exit_path) if exit_path
    end
  end

  def test_wait_until_done_blocks_while_pid_is_alive_despite_stale_exit_file
    Dir.mktmpdir("harnex-wait-stale-exit") do |repo|
      system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      id = "stale-exit-worker"
      exit_path = Harnex.exit_status_path(repo, id)
      registry_path = Harnex.registry_path(repo, id)
      child_pid = spawn("sleep", "30")

      # Leftover exit file from an earlier dispatch that reused the id.
      File.write(exit_path, JSON.generate(
        ok: true, id: id, exit_code: 0, state: "completed",
        session_id: "previous-run", exited_at: (Time.now - 3600).iso8601
      ))
      Harnex.write_registry(registry_path, {
        "id" => id,
        "pid" => child_pid,
        "session_id" => "current-run",
        "host" => "127.0.0.1",
        "port" => 19_996,
        "started_at" => Time.now.iso8601,
        "repo_root" => repo
      })

      waiter = Harnex::Waiter.new(["--repo", repo, "--id", id, "--until", "done", "--timeout", "1"])
      out, = capture_io { assert_equal 124, waiter.run }

      payload = JSON.parse(out)
      refute payload["ok"]
      assert_equal "timeout", payload["status"]
      assert_equal "timeout", payload["wait_result"]
      assert_equal "running", payload["work_state"]
    ensure
      reap_process(child_pid)
      FileUtils.rm_f(exit_path) if exit_path
      FileUtils.rm_f(registry_path) if registry_path
    end
  end

  # Issue #75: stopping a sibling session must not kill the observer watching
  # a different, still-busy session in the same repo.
  def test_wait_until_done_keeps_waiting_when_a_sibling_registry_vanishes
    Dir.mktmpdir("harnex-wait-sibling-vanish") do |repo|
      system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      id = "busy-worker-75"
      registry_path = Harnex.registry_path(repo, id)
      sibling_path = Harnex.registry_path(repo, "stopped-sibling-75")
      child_pid = spawn("sleep", "30")
      sibling_pid = spawn("sleep", "30")
      [[registry_path, id, child_pid], [sibling_path, "stopped-sibling-75", sibling_pid]].each do |path, sid, pid|
        Harnex.write_registry(path, {
          "id" => sid,
          "pid" => pid,
          "session_id" => "#{sid}-run",
          "host" => "127.0.0.1",
          "port" => 19_995,
          "started_at" => Time.now.iso8601,
          "repo_root" => repo
        })
      end
      # The sibling's registry disappears after the observer's glob but before
      # its read, as when `harnex stop` finalizes it mid-scan.
      original_read = File.method(:read)
      vanishing_read = lambda do |path, *args, **kwargs|
        if path == sibling_path
          FileUtils.rm_f(sibling_path)
          raise Errno::ENOENT, sibling_path
        end
        original_read.call(path, *args, **kwargs)
      end

      waiter = Harnex::Waiter.new(["--repo", repo, "--id", id, "--until", "done", "--timeout", "1"])
      out, = File.stub(:read, vanishing_read) { capture_io { assert_equal 124, waiter.run } }

      payload = JSON.parse(out)
      assert_equal "timeout", payload["status"]
      assert_equal "running", payload["work_state"]
    ensure
      reap_process(child_pid) if child_pid
      reap_process(sibling_pid) if sibling_pid
      FileUtils.rm_f(registry_path) if registry_path
      FileUtils.rm_f(sibling_path) if sibling_path
    end
  end

  def test_wait_until_done_ignores_stale_events_from_previous_run_of_same_id
    Dir.mktmpdir("harnex-wait-stale-events") do |repo|
      system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      id = "stale-events-worker"
      events_path = Harnex.events_log_path(repo, id)
      registry_path = Harnex.registry_path(repo, id)
      child_pid = spawn("sleep", "30")

      # task_complete written by an earlier dispatch that reused the id.
      stale_ts = (Time.now - 3600).utc.iso8601
      File.write(events_path, JSON.generate(
        schema_version: 1, seq: 9, ts: stale_ts, id: id, type: "task_complete"
      ) + "\n")
      Harnex.write_registry(registry_path, {
        "id" => id,
        "pid" => child_pid,
        "host" => "127.0.0.1",
        "port" => 19_995,
        "started_at" => Time.now.iso8601,
        "repo_root" => repo
      })

      waiter = Harnex::Waiter.new(["--repo", repo, "--id", id, "--until", "done", "--timeout", "1"])
      out, = capture_io { assert_equal 124, waiter.run }
      assert_equal "timeout", JSON.parse(out)["wait_result"]
    ensure
      reap_process(child_pid)
      FileUtils.rm_f(events_path) if events_path
      FileUtils.rm_f(registry_path) if registry_path
    end
  end

  def test_wait_until_done_blocks_via_start_record_when_registry_is_missing
    Dir.mktmpdir("harnex-wait-start-record") do |repo|
      system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
      id = "start-record-worker"
      child_pid = spawn("sleep", "30")
      Harnex::DispatchHistory.append(
        Harnex::DispatchHistory.path_for(repo),
        schema_version: 1, record_type: "dispatch_start", id: id,
        session_id: "sess-start", pid: child_pid, host: Harnex.host_info[:host],
        cli: "ruby", description: nil, started_at: Time.now.utc.iso8601,
        repo_root: repo, tier: nil, meta: {},
        events_log_path: Harnex.events_log_path(repo, id)
      )

      waiter = Harnex::Waiter.new(["--repo", repo, "--id", id, "--until", "done", "--timeout", "1"])
      out, = capture_io { assert_equal 124, waiter.run }

      payload = JSON.parse(out)
      assert_equal "timeout", payload["wait_result"]
      assert_equal "running", payload["work_state"]
    ensure
      reap_process(child_pid)
    end
  end

  # --- wait-until-exit blocks until DISPATCH row + exit-status file land ---

  def test_wait_until_exit_blocks_until_exit_status_file_lands
    prev_grace = ENV["HARNEX_EXIT_STATUS_GRACE_SECONDS"]
    ENV["HARNEX_EXIT_STATUS_GRACE_SECONDS"] = "2"

    repo_root = Dir.pwd
    id = "racing-worker-#{$$}"
    registry_path = Harnex.registry_path(repo_root, id)
    exit_path = Harnex.exit_status_path(repo_root, id)
    dispatch_dir = Dir.mktmpdir("harnex-dispatch-test")
    dispatch_path = File.join(dispatch_dir, "DISPATCH.jsonl")

    child_pid = spawn("sleep", "5")

    Harnex.write_registry(registry_path, {
      "id" => id,
      "pid" => child_pid,
      "host" => "127.0.0.1",
      "port" => 19998,
      "repo_root" => repo_root
    })

    # Mirror harnex teardown ordering: kill the agent subprocess, then
    # write the DISPATCH row, then the exit-status file. wait must
    # block until the row is on disk.
    killer = Thread.new do
      sleep 0.2
      Process.kill("KILL", child_pid)
      Process.wait(child_pid)
      sleep 0.1
      File.write(dispatch_path, JSON.generate(meta: { id: id }) + "\n")
      sleep 0.05
      File.write(exit_path, JSON.generate(ok: true, id: id, exit_code: 0, status: "exited"))
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    waiter = Harnex::Waiter.new(["--id", id])
    out, = capture_io { assert_equal 0, waiter.run }
    data = JSON.parse(out)
    assert_equal id, data["id"]
    assert File.exist?(dispatch_path), "DISPATCH row not on disk when wait returned"
    row = JSON.parse(File.read(dispatch_path).each_line.first)
    assert_equal id, row.dig("meta", "id")
  ensure
    ENV["HARNEX_EXIT_STATUS_GRACE_SECONDS"] = prev_grace
    reap_thread(killer)
    reap_process(child_pid)
    FileUtils.rm_f(registry_path) if registry_path
    FileUtils.rm_f(exit_path) if exit_path
    FileUtils.rm_rf(dispatch_dir) if dispatch_dir
  end

  # --- bare wait hints (#49) ---

  def test_bare_wait_hints_on_entry_and_when_turn_settles_mid_wait
    run_bare_wait_scenario(auto_stop: false) do |events_path, id|
      sleep 0.3
      File.write(events_path, JSON.generate(seq: 9, ts: Time.now.utc.iso8601, id: id, type: "task_complete") + "\n", mode: "a")
      sleep 0.8
    end => { err: }

    assert_includes err, "was not started with --auto-stop"
    assert_includes err, "reached task_complete but is still alive"
    assert_equal 2, err.scan("Use --until done").length, "entry and mid-wait notes, once each"
  end

  def test_bare_wait_on_already_settled_session_says_so_once
    run_bare_wait_scenario(auto_stop: false, settled_before: true) { sleep 0.8 } => { err: }

    assert_includes err, "already reached task_complete and stays alive"
    assert_equal 1, err.scan("Use --until done").length
  end

  def test_bare_wait_ignores_settled_events_from_a_previous_run_of_the_id
    run_bare_wait_scenario(auto_stop: false, stale_settled: true) { sleep 0.8 } => { err: }

    refute_includes err, "already reached"
    assert_includes err, "was not started with --auto-stop"
  end

  def test_bare_wait_on_auto_stop_session_prints_no_hint
    run_bare_wait_scenario(auto_stop: true) { sleep 0.3 } => { err: }

    refute_includes err, "--until done"
  end

  # --- wait-until-state detects process exit ---

  def test_until_prompt_returns_1_when_process_exits
    repo_root = Dir.pwd
    id = "dead-worker-#{$$}"

    # Spawn and wait so we have a dead PID
    dead_pid = spawn("true")
    Process.wait(dead_pid)

    registry_path = Harnex.registry_path(repo_root, id)
    Harnex.write_registry(registry_path, {
      "id" => id,
      "pid" => dead_pid,
      "host" => "127.0.0.1",
      "port" => 19999,
      "repo_root" => repo_root
    })

    waiter = Harnex::Waiter.new(["--id", id, "--until", "prompt"])
    out, err = capture_io { assert_equal 1, waiter.run }

    # The dead PID means read_registry returns nil (active_sessions cleans it),
    # so we get "no session found" on stderr
    if out.empty?
      assert_match(/no session found/, err)
    else
      data = JSON.parse(out)
      refute data["ok"]
      assert_equal "exited", data["state"]
    end
  ensure
    FileUtils.rm_f(registry_path) if registry_path
  end

  private

  # Runs a bare `harnex wait` against a live fake session. The block runs in
  # a thread while wait blocks; afterwards the child is killed and an exit
  # file written so wait returns. Returns captured stderr.
  def run_bare_wait_scenario(auto_stop:, settled_before: false, stale_settled: false)
    prev_grace = ENV["HARNEX_EXIT_STATUS_GRACE_SECONDS"]
    ENV["HARNEX_EXIT_STATUS_GRACE_SECONDS"] = "2"
    repo_root = Dir.pwd
    id = "bare-wait-#{$$}-#{rand(1_000_000)}"
    registry_path = Harnex.registry_path(repo_root, id)
    exit_path = Harnex.exit_status_path(repo_root, id)
    events_path = Harnex.events_log_path(repo_root, id)
    FileUtils.mkdir_p(File.dirname(events_path))
    started_at = Time.now.utc
    child_pid = spawn("sleep", "10")

    File.write(events_path, "")
    if stale_settled
      File.write(events_path, JSON.generate(seq: 1, ts: (started_at - 3600).iso8601, id: id, type: "task_complete") + "\n")
    end
    if settled_before
      File.write(events_path, JSON.generate(seq: 2, ts: started_at.iso8601, id: id, type: "task_complete") + "\n", mode: "a")
    end
    Harnex.write_registry(registry_path, {
      "id" => id, "pid" => child_pid, "host" => "127.0.0.1", "port" => 19_997,
      "repo_root" => repo_root, "started_at" => started_at.iso8601, "auto_stop" => auto_stop
    })

    driver = Thread.new do
      yield events_path, id
      Process.kill("KILL", child_pid)
      Process.wait(child_pid)
      File.write(exit_path, JSON.generate(ok: true, id: id, exit_code: 0, status: "exited"))
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    _out, err = capture_io { assert_equal 0, Harnex::Waiter.new(["--id", id]).run }
    { err: err }
  ensure
    ENV["HARNEX_EXIT_STATUS_GRACE_SECONDS"] = prev_grace
    reap_thread(driver)
    reap_process(child_pid)
    [registry_path, exit_path, events_path].compact.each { |path| FileUtils.rm_f(path) }
  end
end
