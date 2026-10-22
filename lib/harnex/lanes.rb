require "fileutils"
require "json"
require "net/http"
require "open3"
require "shellwords"
require "time"

module Harnex
  # #87: a lane is the agent-facing unit of delegated work. Its name is also
  # its session id; a delegate lane may own a git worktree on branch
  # harnex/<name>. A record under STATE_DIR/lanes lets `result`, `reply`,
  # `land` and `discard` find a lane by name from anywhere in its repo.
  #
  # Record states: running (a turn is out and nobody has collected it),
  # done, failed, landed, discarded.
  module Lanes
    NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,47}\z/
    BRANCH_PREFIX = "harnex/".freeze
    WORKTREES_DIR = File.join(".harnex", "worktrees").freeze
    CLOSED_STATES = %w[landed discarded].freeze
    DEFAULT_TIMEOUT = 540

    module_function

    def dir
      File.join(STATE_DIR, "lanes")
    end

    def path(repo_root, name)
      File.join(dir, "#{Harnex.repo_key(repo_root)}--#{name}.json")
    end

    def validate_name!(name)
      return name if name.to_s.match?(NAME)

      raise OptionParser::InvalidArgument, "lane name #{name.inspect}: use 1-48 letters, digits, '.', '_' or '-'"
    end

    def save(lane)
      lane["updated_at"] = now
      Harnex.atomic_write_json(path(lane["repo_root"], lane["name"]), lane)
      lane
    end

    def load(repo_root, name)
      JSON.parse(File.read(path(repo_root, name)))
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    def all
      Dir.glob(File.join(dir, "*.json")).filter_map do |file|
        JSON.parse(File.read(file))
      rescue JSON::ParserError, Errno::ENOENT
        nil
      end
    end

    def open?(lane)
      lane && !CLOSED_STATES.include?(lane["state"])
    end

    # A name resolves to this repo's lane first, then to the only lane
    # anywhere with that name.
    def resolve(name, from: Dir.pwd)
      root = main_root(from)
      lane = root && load(root, name)
      return lane if lane

      matches = all.select { |candidate| candidate["name"] == name }
      return matches.first if matches.one?
      raise OptionParser::InvalidArgument, "no lane named #{name.inspect} (see `harnex lanes`)" if matches.empty?

      raise OptionParser::InvalidArgument,
            "several lanes are named #{name.inspect} (#{matches.map { |l| l['repo_root'] }.join(', ')}); run from the lane's repo"
    end

    # Lanes this caller started in this repo whose current turn nobody has
    # collected yet.
    def pending(from: Dir.pwd, owner: Harnex.ambient_owner_id)
      root = main_root(from) || File.expand_path(from)
      all.select { |lane| lane["repo_root"] == root && lane["owner"] == owner && lane["state"] == "running" }
         .sort_by { |lane| lane["launched_at"].to_s }
    end

    FILLER = %w[a an the this that these those to of in on at for from with and or but it its please
                run use add make have has can could would should will do does just then also your you
                our my me i we gpt worker workers task repo repository git command file files code].freeze

    def generate_name(root, task, prefix: "pi")
      words = task.to_s.downcase.scan(/[a-z0-9]+/).reject { |word| FILLER.include?(word) }.first(4)
      base = ([prefix] + words).join("-")[0, 40].sub(/-+\z/, "")
      name = base
      index = 2
      while open?(load(root, name)) || Harnex.read_registry(root, name)
        name = "#{base}-#{index}"
        index += 1
      end
      name
    end

    def live?(lane)
      registry = Harnex.read_registry(lane["run_root"], lane["name"])
      !registry.nil? && Harnex.alive_pid?(registry["pid"])
    end

    # The live worker's activity snapshot (see ActivityTracker), or nil.
    def activity(lane)
      registry = Harnex.read_registry(lane["run_root"], lane["name"])
      return nil unless registry && Harnex.alive_pid?(registry["pid"])

      uri = URI("http://#{registry['host']}:#{registry['port']}/status")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{registry['token']}" if registry["token"]
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 0.5, read_timeout: 0.5) { |http| http.request(request) }
      response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body)["activity"] : nil
    rescue StandardError
      nil
    end

    # "wc: working 2m10s · 7 tool calls · now bash (12s)"
    def progress_line(lane)
      line = "#{lane['name']}: working #{duration(lane['launched_at'])}"
      act = activity(lane)
      return line unless act.is_a?(Hash)

      line += " · #{act['tool_calls']} tool call#{act['tool_calls'] == 1 ? '' : 's'}" if act["tool_calls"].to_i.positive?
      if act["current_tool"]
        line + " · now #{act['current_tool']} #{act['current_tool_s'].to_i}s"
      elsif act["model_active"]
        line + " · thinking"
      else
        line
      end
    end

    # ---- git ---------------------------------------------------------------

    def git(dir, *args)
      out, err, status = Open3.capture3("git", "-C", dir.to_s, *args)
      [out.strip, err.strip, status.success?]
    end

    # The main checkout of the repo that contains `path` (also from inside one
    # of its worktrees), or nil outside git.
    def main_root(path)
      common, _err, ok = git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")
      return nil unless ok

      return File.dirname(common) if File.basename(common) == ".git"

      top, _err, ok = git(path, "rev-parse", "--show-toplevel")
      ok ? top : nil
    end

    def head_sha(dir)
      sha, _err, ok = git(dir, "rev-parse", "HEAD")
      ok ? sha : nil
    end

    def dirty_paths(dir)
      out, _err, ok = git(dir, "status", "--porcelain")
      ok ? out.lines.map { |line| line[3..].to_s.strip } : []
    end

    def create_worktree(root, name)
      Harnex.ensure_git_excluded(root)
      worktree = File.join(root, WORKTREES_DIR, name)
      branch = BRANCH_PREFIX + name
      _out, _err, exists = git(root, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}")
      if exists || File.exist?(worktree)
        raise OptionParser::InvalidArgument,
              "branch #{branch} or #{relative(root, worktree)} already exists; `harnex discard #{name}` or pick another name"
      end

      base = head_sha(root)
      raise OptionParser::InvalidArgument, "#{root} has no commits yet; commit once before using --worktree" unless base

      _out, err, ok = git(root, "worktree", "add", "-q", "-b", branch, worktree, base)
      raise OptionParser::InvalidArgument, "git worktree add failed: #{err}" unless ok

      [worktree, branch, base]
    end

    def remove_worktree(lane, force: false)
      worktree = lane["worktree"]
      if worktree && File.directory?(worktree)
        args = ["worktree", "remove"]
        args << "--force" if force
        _out, err, ok = git(lane["repo_root"], *args, worktree)
        return [false, err] unless ok
      end
      git(lane["repo_root"], "worktree", "prune")
      branch = lane["branch"]
      git(lane["repo_root"], "branch", force ? "-D" : "-d", branch) if branch
      [true, nil]
    end

    # Lanes whose branch the caller merged by hand: once harnex/NAME is in
    # HEAD and the worktree is clean, the lane is landed; tidy it (#87).
    def sweep_merged(root)
      prune_closed
      return [] unless root

      tidied = all.select { |lane| lane["repo_root"] == root && sweepable?(lane) }
      tidied.each do |lane|
        removed, = remove_worktree(lane)
        next unless removed

        lane["state"] = "landed"
        lane["landed_at"] = now
        lane["landed_by"] = "merged outside harnex land"
        save(lane)
      end
      tidied.map { |lane| lane["name"] }
    end

    CLOSED_RETENTION_DAYS = 30

    # Landed and discarded lanes leave only their record and brief; drop
    # both once they are a month old. Open lanes are never pruned.
    def prune_closed(now: Time.now)
      cutoff = now - CLOSED_RETENTION_DAYS * 86_400
      all.each do |lane|
        next unless CLOSED_STATES.include?(lane["state"])

        closed_at = Time.iso8601((lane["landed_at"] || lane["updated_at"]).to_s)
        next if closed_at > cutoff

        FileUtils.rm_f(path(lane["repo_root"], lane["name"]))
        FileUtils.rm_f(File.join(dir, "briefs", "#{Harnex.repo_key(lane['repo_root'])}--#{lane['name']}.md"))
      rescue ArgumentError
        next
      end
    end

    def sweepable?(lane)
      return false unless %w[done failed].include?(lane["state"]) && lane["branch"] && lane["base_sha"]

      tip = head_sha(lane["worktree"] || lane["repo_root"])
      branch_tip, _err, ok = git(lane["repo_root"], "rev-parse", "--verify", "--quiet", lane["branch"])
      return false unless ok && branch_tip != lane["base_sha"]
      return false if lane["worktree"] && File.directory?(lane["worktree"]) && (dirty_paths(lane["worktree"]).any? || tip != branch_tip)
      return false if live?(lane)

      _out, _err, merged = git(lane["repo_root"], "merge-base", "--is-ancestor", lane["branch"], "HEAD")
      merged
    end

    def relative(root, path)
      path.to_s.start_with?("#{root}/") ? path.to_s.delete_prefix("#{root}/") : path.to_s
    end

    # ---- briefs ------------------------------------------------------------

    def write_brief(lane, task)
      file = File.join(dir, "briefs", "#{Harnex.repo_key(lane['repo_root'])}--#{lane['name']}.md")
      footer = if lane["branch"]
                 "You are working in a git worktree on branch #{lane['branch']}; the main checkout is not " \
                   "affected. When you are done, commit your changes on this branch, then reply with a short " \
                   "summary: what you changed, how you verified it, and anything left undone."
               else
                 "When you are done, reply with a short summary: what you changed, how you verified it, and " \
                   "anything left undone."
               end
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "#{task.to_s.rstrip}\n\n---\nharnex: #{footer}\n")
      file
    end

    # ---- launching and waiting ---------------------------------------------

    # Starts (or restarts) the lane's Pi worker. With wait, blocks for the
    # turn's result and returns [turn, exit_code] (exit codes of wait --until
    # done); without, returns [launch_payload, 0]. A launch that fails before
    # any result (bad flag, busy id, no tmux) raises with harnex's message.
    def launch(lane, harnex_command, context_args:, child_args: [], wait: true, timeout: DEFAULT_TIMEOUT, detach: false)
      lane["launched_at"] = now
      lane["state"] = "running"
      lane.delete("after_seq")
      lane.delete("last_error")
      save(lane)

      argv = harnex_command + ["run", "pi", "--id", lane["name"]]
      argv += detach ? ["--detach"] : ["--tmux", lane["name"]]
      argv += ["--cwd", lane["cwd"], "--root", lane["run_root"], "--auto-stop", "--intent", lane["kind"]]
      argv += context_args
      argv += ["--model", lane["requested_model"]] if lane["requested_model"]
      argv += ["--effort", lane["effort"]] if lane["effort"]
      argv += ["--wait-done"] + (timeout ? ["--wait-timeout", timeout.to_s] : []) if wait
      argv += ["--"] + child_args unless child_args.empty?
      stdout, stderr, status = Open3.capture3(*argv)
      payload = last_json(stdout)
      if payload.empty?
        lane["state"] = "failed"
        lane["last_error"] = stderr.strip.lines.last.to_s.strip
        save(lane)
        raise LaunchError, "harnex could not start lane #{lane['name']}: #{stderr.strip.lines.last(3).join.strip}"
      end
      return [payload, 0] unless wait

      [payload["turn_result"] || payload, status.exitstatus]
    end

    def wait(lane, harnex_command, timeout: DEFAULT_TIMEOUT)
      argv = harnex_command + ["wait", "--id", lane["name"], "--repo", lane["run_root"], "--until", "done",
                               "--since", lane["launched_at"]]
      argv += ["--after-seq", lane["after_seq"].to_s] if lane["after_seq"]
      argv += ["--timeout", timeout.to_s] if timeout
      stdout, _stderr, status = Open3.capture3(*argv)
      [last_json(stdout), status.exitstatus]
    end

    def last_json(stdout)
      JSON.parse(stdout.to_s.lines.reverse.find { |line| line.start_with?("{") }.to_s)
    rescue JSON::ParserError
      {}
    end

    class LaunchError < StandardError; end

    # Shared by the lane commands: `--timeout none` waits without a cap.
    def parse_timeout(value, option_name: "--timeout")
      return nil if %w[none 0].include?(value.to_s)

      Harnex.parse_duration_seconds(value, option_name: option_name)
    end

    # ---- outcomes ----------------------------------------------------------

    # The usage event of the launch that started at `since` (written right
    # after the worker exits, so give it a moment).
    def usage_since(lane, since, wait_seconds: 3.0)
      return nil unless File.exist?(Harnex.events_log_path(lane["run_root"], lane["name"]))

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_seconds
      loop do
        found = events(lane).reverse.find { |e| e["type"] == "usage" && after?(e["ts"], since) }
        return found if found
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.2
      end
    end

    def events(lane)
      File.readlines(Harnex.events_log_path(lane["run_root"], lane["name"])).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    rescue Errno::ENOENT
      []
    end

    def after?(ts, since)
      return true if since.nil?

      Time.iso8601(ts.to_s) >= Time.iso8601(since.to_s)
    rescue ArgumentError
      false
    end

    def now
      Time.now.utc.iso8601(3)
    end

    # Records the outcome of the pending turn. `turn` is the result object of
    # `wait --until done` (or run/send --wait-done's turn_result); exit_code
    # follows wait: 0 done, 124 still working, else failed.
    def settle(lane, turn, exit_code)
      return lane if exit_code == Waiter::DONE_EXIT_TIMEOUT

      lane["state"] = exit_code.zero? ? "done" : "failed"
      lane["outcome"] = turn["outcome_class"] || turn["status"]
      lane["last_error"] = turn["last_error"] if turn["last_error"]
      lane["model"] = turn["model"] if turn["model"]
      usage = usage_since(lane, lane["launched_at"])
      if usage
        lane["agent_session_id"] = usage["agent_session_id"] if usage["agent_session_id"]
        lane["cost_usd"] = (lane["cost_usd"].to_f + usage["cost_usd"].to_f).round(4) if usage["cost_usd"]
      end
      lane["turns"] = lane["turns"].to_i + 1
      lane["settled_at"] = now
      # Kept so a later `harnex result NAME` can show the result again.
      lane["last_turn"] = turn.slice("final_message", "final_message_path", "final_message_truncated", "model",
                                     "outcome_class", "status", "last_error", "end_sha")
      save(lane)
    end

    def final_message(turn)
      path = turn["final_message_path"].to_s
      return File.read(path).chomp if turn["final_message_truncated"] && !path.empty? && File.file?(path)

      turn["final_message"].to_s
    rescue StandardError
      turn["final_message"].to_s
    end

    # ---- rendering ---------------------------------------------------------

    def render(lane, turn, exit_code)
      lines = []
      message = final_message(turn)
      lines << message.rstrip << "" unless message.strip.empty? || exit_code == Waiter::DONE_EXIT_TIMEOUT
      lines << "── #{lane['name']}: #{headline(lane, turn, exit_code)}"
      lines.concat(details(lane, exit_code).map { |line| "   #{line}" })
      lines.join("\n")
    end

    def headline(lane, turn, exit_code)
      model = turn["model"] || lane["model"] || lane["requested_model"]
      parts = []
      case exit_code
      when 0
        parts << "done in #{duration(lane['launched_at'])}"
      when Waiter::DONE_EXIT_TIMEOUT
        parts << "still working (#{duration(lane['launched_at'])} so far)"
      else
        reason = turn["last_error"] || turn["outcome_class"] || turn["status"] || "no result"
        parts << "FAILED after #{duration(lane['launched_at'])} (#{reason.to_s.lines.first.to_s.strip[0, 160]})"
      end
      parts << model if model
      parts << format("$%.2f", lane["cost_usd"]) if lane["cost_usd"] && exit_code != Waiter::DONE_EXIT_TIMEOUT
      parts << change_summary(lane) if exit_code != Waiter::DONE_EXIT_TIMEOUT && lane["kind"] != "ask"
      parts.compact.join(" · ")
    end

    def change_summary(lane)
      dir = lane["worktree"] || lane["cwd"]
      return nil unless lane["base_sha"] && File.directory?(dir.to_s)

      count, _err, ok = git(dir, "rev-list", "--count", "#{lane['base_sha']}..HEAD")
      return nil unless ok

      stat, = git(dir, "diff", "--shortstat", lane["base_sha"], "HEAD")
      commits = "#{count} commit#{count == '1' ? '' : 's'}"
      stat.empty? ? commits : "#{commits}, #{compact_stat(stat)}"
    end

    def compact_stat(stat)
      files = stat[/(\d+) files? changed/, 1]
      added = stat[/(\d+) insertions?/, 1]
      removed = stat[/(\d+) deletions?/, 1]
      "#{files} file#{files == '1' ? '' : 's'} (+#{added || 0} -#{removed || 0})"
    end

    def details(lane, exit_code)
      name = lane["name"]
      return ["keep waiting: harnex result #{name}"] if exit_code == Waiter::DONE_EXIT_TIMEOUT
      return ["more: harnex reply #{name} \"...\""] if lane["kind"] == "ask"

      out = []
      dirty = lane["worktree"] ? dirty_paths(lane["worktree"]) : []
      if lane["worktree"]
        out << "worktree #{relative(lane['repo_root'], lane['worktree'])} (branch #{lane['branch']})" \
               "#{dirty.empty? ? '' : ", #{dirty.length} uncommitted file#{dirty.length == 1 ? '' : 's'}"}"
      end
      if exit_code.zero?
        if lane["branch"] && commit_count(lane).zero? && dirty.empty?
          out << "next: no commits to merge; `harnex land #{name}` removes the worktree; " \
                 "more work: `harnex reply #{name} \"...\"`"
        elsif lane["branch"]
          out << "next: review `git diff HEAD...#{lane['branch']}`, then `harnex land #{name}` (merges and removes " \
                 "the worktree and branch; use it instead of git merge); more work: `harnex reply #{name} \"...\"`; " \
                 "drop it: `harnex discard #{name}`"
        else
          out << "worked in place in #{lane['cwd']}; more work: `harnex reply #{name} \"...\"`"
        end
      else
        retry_model = model_problem?(lane) ? other_model(lane) : nil
        out << "next: `harnex reply #{name} \"Continue the same task from where you stopped\"" \
               "#{retry_model ? " --model #{retry_model}" : ''}`" \
               "#{retry_model ? ' (keeps the task; another model)' : ''}" \
               "#{lane['branch'] ? " or `harnex discard #{name}`" : ''}"
      end
      out
    end

    def commit_count(lane)
      count, _err, ok = git(lane["worktree"] || lane["cwd"], "rev-list", "--count", "#{lane['base_sha']}..HEAD")
      ok ? count.to_i : 0
    end

    MODEL_PROBLEM = /model_not_found|model not found|rate.?limit|capacity|overloaded|quota|429|\b404\b|unknown model|provider/i

    def model_problem?(lane)
      lane["outcome"].to_s == "provider_capacity" || lane["last_error"].to_s.match?(MODEL_PROBLEM)
    end

    # Pi's default model, unless that is the one that just failed.
    def other_model(lane)
      settings = JSON.parse(File.read(File.join(ENV["PI_CODING_AGENT_DIR"] || File.expand_path("~/.pi/agent"), "settings.json")))
      default = [settings["defaultProvider"], settings["defaultModel"]].compact.join("/")
      failed = lane["requested_model"].to_s
      return nil if default.empty? || failed.empty? || failed.end_with?(settings["defaultModel"].to_s)

      default
    rescue StandardError
      nil
    end

    def duration(since)
      seconds = (Time.now - Time.iso8601(since.to_s)).to_i
      return "#{seconds}s" if seconds < 60
      return format("%dm%02ds", seconds / 60, seconds % 60) if seconds < 3600

      format("%dh%02dm", seconds / 3600, (seconds % 3600) / 60)
    rescue ArgumentError
      "?"
    end
  end
end
