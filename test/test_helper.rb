require "minitest/autorun"
require "tmpdir"
require "fileutils"

# Isolate state dir so tests never touch real sessions
ENV["HARNEX_STATE_DIR"] = Dir.mktmpdir("harnex-test-state")

# Clear any session env that would pollute tests
%w[
  HARNEX_ID HARNEX_DESCRIPTION HARNEX_SESSION_ID HARNEX_SESSION_CLI
  HARNEX_SESSION_REPO_ROOT HARNEX_HOST HARNEX_BASE_PORT
  HARNEX_PORT_SPAN HARNEX_TRACE HARNEX_ARTIFACT_REPORT_PATH
  HARNEX_VALIDATION_REPORT_PATH HARNEX_ARTIFACT_CLAIMS_PATH
  HARNEX_ARTIFACT_REPORT_SCHEMA HARNEX_ARTIFACT_REPORT_MODE
  HARNEX_ARTIFACT_REPORT_REQUIRED
].each { |key| ENV.delete(key) }

require_relative "../lib/harnex"

# Cross-test isolation.
#
# The whole suite runs in one process, and several suites deliberately wipe
# shared state directories (the doctor sweep wipes SESSIONS_DIR; retention
# wipes events/output/receipts). A test that leaks a live thread -- especially
# one running a Harnex::Session, which writes registries and the dispatch
# stream -- therefore blows up inside an unrelated later test, in random
# order, at a random seed. Reaping leaked concurrency at the test boundary
# removes the whole class of cross-test contamination.
module HarnexTestIsolation
  def before_setup
    super
    @__threads_at_start = Thread.list
  end

  def after_teardown
    super
    reap_leaked_threads
  end

  # Thread#kill is asynchronous: a killed thread can still be unwinding, and
  # still writing files, after #kill returns. Confirm death before moving on.
  def reap_thread(thread, timeout: 5)
    return nil unless thread
    return thread unless thread.alive?
    return thread if thread.join(timeout)

    thread.kill
    thread.join(timeout)
    thread
  end

  # SIGKILL is asynchronous too, and waitpid(WNOHANG) does not wait at all --
  # it just reports "not dead yet". Block until the child is really gone so it
  # cannot keep writing while a later test wipes shared directories.
  def reap_process(pid, signal: "KILL", timeout: 5)
    return unless pid

    begin
      Process.kill(signal, pid)
    rescue Errno::ESRCH, Errno::EPERM, ArgumentError, TypeError
      nil
    end

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      break if Process.waitpid(pid, Process::WNOHANG)
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  end

  private

  def reap_leaked_threads
    started_before = @__threads_at_start || []
    (Thread.list - started_before - [Thread.current]).each do |thread|
      next unless thread.alive?

      thread.kill
      thread.join(5)
    end
  end
end

Minitest::Test.include(HarnexTestIsolation)

# Clean up temp state dir when tests finish
Minitest.after_run do
  FileUtils.rm_rf(ENV["HARNEX_STATE_DIR"])
end
