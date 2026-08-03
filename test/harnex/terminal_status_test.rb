require "json"

require_relative "../test_helper"

class TerminalStatusTest < Minitest::Test
  def test_resolves_v2_end_row_as_summary_and_history_in_one_shot
    Dir.mktmpdir("harnex-terminal-v2") do |repo|
      init_git_repo(repo)
      path = Harnex::DispatchHistory.path_for(repo)
      Harnex::DispatchHistory.append(path, v2_end_row(id: "cx-v2", repo: repo))

      status = Harnex::TerminalStatus.resolve(id: "cx-v2", repo_root: repo)

      assert status
      assert_equal "cx-v2", status["id"]
      assert_equal "completed", status["state"]
      assert_equal true, status["terminal"]
      assert_equal true, status["task_complete"]
      assert_equal "completed_with_proof", status["outcome_class"]
      assert_equal "success", status["exit"]
      assert_equal 0, status["exit_code"]
      assert_equal "dispatch_end", status["source"]
      refute status.key?("summary_out"), "removed mirror key must not reappear"
    end
  end

  # The mirror writer is gone, but consumers still have mirror files from
  # older releases on disk. A stale one must not resolve status for any id.
  def test_pre_existing_mirror_file_does_not_influence_resolution
    Dir.mktmpdir("harnex-terminal-stale-mirror") do |repo|
      init_git_repo(repo)
      path = Harnex::DispatchHistory.path_for(repo)
      mirror = File.join(repo, "tmp", "dispatch-summary.jsonl")
      FileUtils.mkdir_p(File.dirname(mirror))

      # A leftover mirror row claiming success for an id the canonical
      # stream has never seen.
      File.write(mirror, "#{JSON.generate(v2_end_row(id: 'cx-stale', repo: repo))}\n")
      assert_nil Harnex::TerminalStatus.resolve(id: "cx-stale", repo_root: repo)

      # And a leftover mirror row that contradicts the canonical outcome,
      # reachable the old way via summary_out_path on the tracked record.
      canonical = v2_end_row(id: "cx-live", repo: repo, ended_at: "2026-08-01T10:15:00Z")
      canonical["status"] = "failed"
      canonical["actual"] = { "task_complete" => false, "exit" => "failure", "exit_code" => 1 }
      canonical["summary_out_path"] = mirror
      Harnex::DispatchHistory.append(path, canonical)

      newer = v2_end_row(id: "cx-live", repo: repo, ended_at: "2026-08-01T11:00:00Z")
      File.write(mirror, "#{JSON.generate(newer)}\n", mode: "a")

      status = Harnex::TerminalStatus.resolve(id: "cx-live", repo_root: repo)
      assert_equal "failed", status["state"]
      assert_equal "failure", status["exit"]
    end
  end

  def test_v2_row_without_rich_sections_still_resolves_as_history
    Dir.mktmpdir("harnex-terminal-v2-bare") do |repo|
      init_git_repo(repo)
      path = Harnex::DispatchHistory.path_for(repo)
      Harnex::DispatchHistory.append(path, {
        "schema_version" => 2,
        "record_type" => "dispatch_end",
        "id" => "cx-bare",
        "status" => "completed",
        "terminal_event" => "process_exit",
        "started_at" => "2026-08-01T06:00:00Z",
        "ended_at" => "2026-08-01T06:05:00Z"
      })

      status = Harnex::TerminalStatus.resolve(id: "cx-bare", repo_root: repo)

      assert status
      assert_equal "completed", status["state"]
      assert_equal "success", status["exit"]
      assert_equal "dispatch_history", status["source"]
    end
  end

  def test_resolves_each_era_from_a_mixed_stream
    Dir.mktmpdir("harnex-terminal-mixed") do |repo|
      init_git_repo(repo)
      path = Harnex::DispatchHistory.path_for(repo)

      # Pre-0.7.3 envelope-less rich row.
      Harnex::DispatchHistory.append(path, {
        "meta" => {
          "id" => "cx-legacy",
          "repo" => repo,
          "started_at" => "2026-07-01T06:00:00Z",
          "ended_at" => "2026-07-01T06:10:00Z"
        },
        "predicted" => {},
        "actual" => { "task_complete" => true, "exit" => "success", "exit_code" => 0 }
      })

      # v1 thin end row without record_type (legacy clause).
      Harnex::DispatchHistory.append(path, {
        "schema_version" => 1,
        "id" => "cx-thin",
        "status" => "failed",
        "terminal_event" => "dispatch_failed",
        "started_at" => "2026-07-02T06:00:00Z",
        "ended_at" => "2026-07-02T06:03:00Z"
      })

      # v2 unified row.
      Harnex::DispatchHistory.append(path, v2_end_row(id: "cx-v2", repo: repo))

      legacy = Harnex::TerminalStatus.resolve(id: "cx-legacy", repo_root: repo)
      assert_equal "completed", legacy["state"]
      assert_equal true, legacy["task_complete"]
      assert_equal "dispatch_end", legacy["source"]

      thin = Harnex::TerminalStatus.resolve(id: "cx-thin", repo_root: repo)
      assert_equal "failed", thin["state"]
      assert_equal "failure", thin["exit"]
      assert_equal "dispatch_history", thin["source"]

      v2 = Harnex::TerminalStatus.resolve(id: "cx-v2", repo_root: repo)
      assert_equal "completed", v2["state"]
      assert_equal "dispatch_end", v2["source"]
    end
  end

  def test_v2_row_id_keyed_on_envelope_not_meta
    Dir.mktmpdir("harnex-terminal-v2-key") do |repo|
      init_git_repo(repo)
      path = Harnex::DispatchHistory.path_for(repo)
      row = v2_end_row(id: "cx-envelope", repo: repo)
      row["meta"]["id"] = "cx-envelope"
      Harnex::DispatchHistory.append(path, row)

      assert Harnex::TerminalStatus.resolve(id: "cx-envelope", repo_root: repo)
      assert_nil Harnex::TerminalStatus.resolve(id: "cx-other", repo_root: repo)
    end
  end

  private

  def v2_end_row(id:, repo:, started_at: "2026-08-01T10:00:00Z", ended_at: "2026-08-01T10:15:00Z")
    {
      "schema_version" => 2,
      "record_type" => "dispatch_end",
      "id" => id,
      "session_id" => "sess-#{id}",
      "description" => "v2 fixture",
      "cli" => "codex",
      "started_at" => started_at,
      "ended_at" => ended_at,
      "duration_s" => 900,
      "status" => "completed",
      "terminal_event" => "task_complete",
      "commit_sha" => nil,
      "tier" => "B",
      "events_log_path" => "/tmp/events.log",
      "tmux_state" => "torn-down",
      "meta" => {
        "id" => id,
        "repo" => repo,
        "started_at" => started_at,
        "ended_at" => ended_at
      },
      "predicted" => {},
      "actual" => { "task_complete" => true, "exit" => "success", "exit_code" => 0 },
      "agent" => { "cli" => "codex" },
      "usage" => { "status" => "unsupported" },
      "context" => { "status" => "unsupported" },
      "attribution" => { "status" => "unattributed" },
      "outcome" => { "class" => "completed_with_proof", "status" => "no_change", "report_status" => nil },
      "attempt" => { "run_id" => id, "kind" => "initial", "status" => "succeeded" },
      "reliability" => { "recovered" => false }
    }
  end

  def init_git_repo(repo)
    system("git", "init", "-q", repo, out: File::NULL, err: File::NULL)
  end
end
