module Harnex
  # `harnex land` / `harnex discard` (#87): finish a worktree lane. Land
  # merges harnex/NAME into the main checkout's current branch, then removes
  # the worktree and branch; on conflict git's merge stays in progress for
  # the caller to resolve, and the next `land` cleans up. Discard drops the
  # lane's work.
  class Land
    def self.usage(discard: false)
      if discard
        <<~TEXT
          Usage: harnex discard NAME...

          Stop a lane (if it is still working) and delete its worktree and branch
          without merging. Uncommitted and unmerged work in the lane is lost.
        TEXT
      else
        <<~TEXT
          Usage: harnex land [NAME...]

          Merge a worktree lane (branch harnex/NAME) into the current branch of the
          main checkout, then remove its worktree and branch. With no NAME: every
          finished worktree lane you started in this repo, oldest first. Uncommitted changes
          in the lane are committed first. On a merge conflict the merge stays in
          progress: resolve it, `git commit`, and run `harnex land NAME` again to
          clean up (or `git merge --abort`).

          Exit codes: 0 landed, 1 conflict or another problem (the lane is kept).
        TEXT
      end
    end

    def initialize(argv, out: $stdout, err: $stderr, discard: false, harnex_command: nil)
      @argv = argv.dup
      @out = out
      @err = err
      @discard = discard
      @harnex_command = harnex_command || [Gem.ruby, File.expand_path("../../../bin/harnex", __dir__)]
    end

    def run
      if (@argv.empty? && @discard) || @argv.any? { |arg| %w[-h --help].include?(arg) }
        @out.puts self.class.usage(discard: @discard)
        return @argv.empty? ? 2 : 0
      end
      flag = @argv.find { |arg| arg.start_with?("-") }
      raise OptionParser::InvalidOption, "harnex #{verb}: unknown flag #{flag}" if flag

      lanes = @argv.empty? ? finished_lanes : @argv.map { |name| Lanes.resolve(name) }
      if lanes.empty?
        @out.puts "no finished worktree lanes to land (see `harnex lanes`)"
        return 0
      end
      lanes.map { |lane| @discard ? discard(lane) : land(lane) }.max
    end

    private

    # `harnex land` alone: the caller's finished worktree lanes in this repo.
    def finished_lanes
      root = Lanes.main_root(Dir.pwd)
      owner = Harnex.ambient_owner_id
      Lanes.all.select { |lane| lane["repo_root"] == root && lane["owner"] == owner && lane["branch"] && lane["state"] == "done" }
           .sort_by { |lane| lane["created_at"].to_s }
    end

    def verb
      @discard ? "discard" : "land"
    end

    def land(lane)
      name = lane["name"]
      return say(lane, "already landed") if lane["state"] == "landed"
      return refuse(lane, "it was discarded") if lane["state"] == "discarded"
      return refuse(lane, "it worked in place (no worktree); its changes are already in #{lane['cwd']}") unless lane["branch"]
      return refuse(lane, "it is still working; wait with `harnex result #{name}` or stop it with `harnex discard #{name}`") if Lanes.live?(lane)

      root = lane["repo_root"]
      if File.exist?(File.join(git_dir(root), "MERGE_HEAD"))
        conflicts = conflicted(root)
        return refuse(lane, "a merge is in progress in #{root}#{conflicts.empty? ? '' : " (conflicts: #{conflicts.join(', ')})"}; " \
                          "finish it with `git commit` (or `git merge --abort`), then run `harnex land #{name}` again")
      end

      committed = commit_leftovers(lane)
      target, = Lanes.git(root, "branch", "--show-current")
      _out, _err, merged = Lanes.git(root, "merge-base", "--is-ancestor", lane["branch"], "HEAD")
      unless merged
        count, = Lanes.git(root, "rev-list", "--count", "HEAD..#{lane['branch']}")
        _out, err, ok = Lanes.git(root, "merge", "--no-edit", lane["branch"])
        unless ok
          conflicts = conflicted(root)
          return refuse(lane, "could not merge #{lane['branch']}: #{err.lines.last.to_s.strip}") if conflicts.empty?

          return refuse(lane, "merge conflict in #{conflicts.join(', ')} (the merge is left in progress in #{root}).\n" \
                            "   next: resolve the files, `git add` them and `git commit`, then `harnex land #{name}` again " \
                            "to clean up; to give up: `git merge --abort`")
        end
      end

      removed, err = Lanes.remove_worktree(lane)
      return refuse(lane, "merged, but could not remove its worktree: #{err}") unless removed

      lane["state"] = "landed"
      lane["landed_at"] = Lanes.now
      Lanes.save(lane)
      what = merged ? "was already merged" : "merged #{lane['branch']} into #{target.empty? ? 'HEAD' : target} (#{count} commit#{count == '1' ? '' : 's'})"
      say(lane, "#{what}#{committed ? '; committed its uncommitted changes first' : ''}; removed its worktree and branch")
    end

    def discard(lane)
      return say(lane, "already #{lane['state']}") if Lanes::CLOSED_STATES.include?(lane["state"])

      if Lanes.live?(lane)
        Open3.capture3(*(@harnex_command + ["stop", "--id", lane["name"], "--repo", lane["run_root"]]))
      end
      Lanes.remove_worktree(lane, force: true) if lane["branch"]
      lane["state"] = "discarded"
      Lanes.save(lane)
      say(lane, lane["branch"] ? "discarded; removed its worktree and branch #{lane['branch']}" : "discarded")
    end

    def commit_leftovers(lane)
      return false unless lane["worktree"] && File.directory?(lane["worktree"]) && Lanes.dirty_paths(lane["worktree"]).any?

      Lanes.git(lane["worktree"], "add", "-A")
      _out, _err, ok = Lanes.git(lane["worktree"], "commit", "-q", "-m", "harnex: uncommitted changes from lane #{lane['name']}")
      ok
    end

    def git_dir(root)
      dir, = Lanes.git(root, "rev-parse", "--absolute-git-dir")
      dir
    end

    def conflicted(root)
      out, = Lanes.git(root, "diff", "--name-only", "--diff-filter=U")
      out.lines.map(&:strip).reject(&:empty?)
    end

    def say(lane, text)
      @out.puts "── #{lane['name']}: #{text}"
      0
    end

    def refuse(lane, text)
      @out.puts "── #{lane['name']}: not landed — #{text}"
      1
    end
  end
end
