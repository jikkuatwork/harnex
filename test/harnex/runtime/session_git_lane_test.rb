require_relative "../../test_helper"
require "open3"

# #80: a lane launched with --cwd <worktree> --root <checkout> is observed in
# its own worktree; supervisor commits on the root never count as its work.
class SessionGitLaneTest < Minitest::Test
  def setup
    @base = Dir.mktmpdir("harnex-git-lane")
    @master = File.join(@base, "master")
    @lane = File.join(@base, "lane")
    git(@base, "init", "-q", "-b", "master", @master)
    git(@master, "config", "user.email", "t@example.com")
    git(@master, "config", "user.name", "T")
    commit(@master, "seed.txt", "seed")
    git(@master, "worktree", "add", "-q", "-b", "night/lane", @lane)
  end

  def teardown
    FileUtils.rm_rf(@base)
  end

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')}: #{out}" unless status.success?

    out.strip
  end

  def commit(dir, file, text)
    File.write(File.join(dir, file), text)
    git(dir, "add", file)
    git(dir, "commit", "-q", "-m", "add #{file}")
    git(dir, "rev-parse", "HEAD")
  end

  def session(child_cwd)
    Harnex::Session.new(adapter: Harnex::Adapters::Pi.new, command: ["pi", "--mode", "rpc"], repo_root: @master,
                        host: "127.0.0.1", id: "pi-lane", child_cwd: child_cwd).tap do |s|
      s.send(:prepare_output_log)
      s.send(:prepare_events_log)
    end
  end

  def test_lane_commit_is_the_dispatch_commit_and_supervisor_commits_are_not
    lane = session(@lane)
    lane.send(:emit_git_start_event)
    assert_equal "night/lane", lane.git_start[:branch]

    supervisor_sha = commit(@master, "review.txt", "review")
    refute lane.send(:git_activity_observed?), "a root commit is not the lane's activity"

    lane_sha = commit(@lane, "fix.txt", "fix")
    lane.send(:emit_session_end_telemetry)

    assert lane.send(:git_activity_observed?)
    assert_equal lane_sha, Harnex::DispatchHistory.commit_sha(lane.git_start, lane.git_end)
    assert_equal supervisor_sha, lane.send(:root_commit_sha)
    start = File.readlines(lane.events_log_path).map { |line| JSON.parse(line) }
                .find { |row| row["type"] == "git" && row["phase"] == "start" }
    assert_equal File.realpath(@lane), start["git_root"]
  end

  def test_cwd_inside_the_root_repository_is_not_a_lane
    sub = File.join(@master, "sub")
    FileUtils.mkdir_p(sub)
    inside = session(sub)

    assert_equal @master, inside.send(:git_observation_root)
    assert_nil inside.send(:root_commit_sha)
  end
end
