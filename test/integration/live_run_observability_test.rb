require_relative "../test_helper"
require "open3"
require "rbconfig"

# Reproduces the Holm Queue 096 failure shape (issue #62): a worker session
# mid-run, with a coordinator checking from a separate process and cwd.
# Every documented signal must read the healthy worker as running — never
# dead — and a retry dispatch must be refused while the parent lives.
class LiveRunObservabilityTest < Minitest::Test
  HARNEX_BIN = File.expand_path("../../bin/harnex", __dir__)
  WORKER_ID = "cx-t-q096-01".freeze

  def test_q096_shape_worker_mid_run_is_visible_and_retry_is_refused
    Dir.mktmpdir("harnex-q096") do |repo|
      init_git_repo(repo)
      checker_cwd = File.join(repo, "sub", "dir")
      FileUtils.mkdir_p(checker_cwd)
      release_path = File.join(repo, "release-worker")
      worker_script = "sleep 0.2 until File.exist?(ARGV[0]); exit 0"

      out, err, spawn_status = harnex(
        "run", RbConfig.ruby,
        "--id", WORKER_ID,
        "--description", "q096 worker",
        "--detach",
        "--", "-e", worker_script, release_path,
        chdir: repo
      )
      assert spawn_status.success?, "worker dispatch failed: #{err}"
      registration = JSON.parse(out)
      worker_pid = registration.fetch("pid")

      # 1. status from another cwd sees the worker running.
      out, err, status = harnex("status", "--id", WORKER_ID, "--json", chdir: checker_cwd)
      assert status.success?, "status failed: #{err}"
      row = JSON.parse(out).first
      assert_equal "running", row["state"], "mid-run worker must read as running, got #{row.inspect}"
      assert_equal false, row["done"]

      # 2. history from another cwd has the start row.
      out, err, status = harnex("history", "--json", "--limit", "10", chdir: checker_cwd)
      assert status.success?, "history failed: #{err}"
      history_row = out.lines.map { |line| JSON.parse(line) }.find { |r| r["id"] == WORKER_ID }
      assert history_row, "history must show the mid-run dispatch"
      assert_equal "running", history_row["status"]
      assert_equal "dispatch_start", history_row["record_type"]

      # 3. wait --until done blocks while the worker is alive (times out, is
      # never classified dead / done early).
      out, _err, status = harnex(
        "wait", "--id", WORKER_ID, "--until", "done", "--timeout", "1.5",
        chdir: checker_cwd
      )
      assert_equal 124, status.exitstatus, "wait must block until timeout while worker is alive, got: #{out}"
      assert_equal "timeout", JSON.parse(out)["wait_result"]

      # 4. retry dispatch is refused while the parent lives.
      _out, err, status = harnex(
        "run", RbConfig.ruby,
        "--id", "#{WORKER_ID}-r1",
        "--attempt-kind", "retry", "--parent-dispatch-id", WORKER_ID,
        "--", "-e", "exit 0",
        chdir: repo
      )
      refute status.success?, "retry must be refused while parent is alive"
      assert_match(/refusing retry dispatch/, err)
      assert_match(/#{WORKER_ID}/, err)

      # 5. Even with the registry row gone, the start record keeps the
      # running worker visible (degraded, but never dead).
      FileUtils.rm_f(Harnex.registry_path(repo, WORKER_ID))
      out, _err, status = harnex("status", "--id", WORKER_ID, "--json", chdir: checker_cwd)
      assert status.success?
      row = JSON.parse(out).first
      assert_equal "running", row["state"]
      assert_equal "dispatch_start", row["source"]
      assert_equal true, row["degraded"]

      # 6. wait --until done blocks until the worker finishes, then reports
      # accepted completion (exit 0).
      wait_out = File.join(repo, "wait-out.json")
      wait_pid = Process.spawn(
        RbConfig.ruby, HARNEX_BIN,
        "wait", "--id", WORKER_ID, "--until", "done", "--timeout", "30",
        chdir: checker_cwd, out: wait_out, err: File::NULL
      )
      sleep 1.2
      assert_nil Process.waitpid(wait_pid, Process::WNOHANG),
                 "wait must still be blocking while the worker runs"

      File.write(release_path, "go\n")
      Process.waitpid(wait_pid)
      assert_equal 0, $?.exitstatus, "wait must exit 0 for accepted completion: #{File.read(wait_out)}"
      payload = JSON.parse(File.read(wait_out))
      assert_equal "done", payload["wait_result"]
      assert payload["done"]

      # 7. After completion the stream pairs up: history shows the end row,
      # and the retry that was refused mid-run is now allowed.
      out, _err, = harnex("history", "--json", "--limit", "10", chdir: checker_cwd)
      rows = out.lines.map { |line| JSON.parse(line) }.select { |r| r["id"] == WORKER_ID }
      assert_equal ["dispatch_end"], rows.map { |r| r["record_type"] },
                   "completed dispatch must render exactly one end row"

      _out, err, status = harnex(
        "run", RbConfig.ruby,
        "--id", "#{WORKER_ID}-r1",
        "--attempt-kind", "retry", "--parent-dispatch-id", WORKER_ID,
        "--", "-e", "exit 0",
        chdir: repo
      )
      assert status.success?, "retry must be allowed once the parent has exited: #{err}"
    ensure
      File.write(release_path, "go\n") if release_path && !File.exist?(release_path)
      begin
        Process.kill("KILL", worker_pid) if worker_pid
      rescue Errno::ESRCH, ArgumentError, TypeError
        nil
      end
    end
  end

  private

  def harnex(*args, chdir:)
    Open3.capture3(RbConfig.ruby, HARNEX_BIN, *args, chdir: chdir)
  end

  def init_git_repo(repo)
    system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
    File.write(File.join(repo, "README.md"), "q096\n")
    system("git", "-C", repo, "add", "README.md", out: File::NULL, err: File::NULL)
    system(
      "git", "-C", repo,
      "-c", "user.email=test@example.com",
      "-c", "user.name=Test",
      "commit", "-q", "-m", "initial",
      out: File::NULL, err: File::NULL
    )
  end
end
