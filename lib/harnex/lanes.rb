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
    # A lane's run is tagged meta.phase = its kind unless the caller names a
    # phase; repo phase allowlists exempt these harnex-owned phases (#88).
    PHASES = %w[delegate ask].freeze

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

    # Older harnex kept the record of a lane refused before it started (#88).
    def never_started?(lane)
      lane && lane["state"] == "failed" && lane["turns"].to_i.zero? && !live?(lane)
    end

    def forget(lane)
      FileUtils.rm_f(path(lane["repo_root"], lane["name"]))
      FileUtils.rm_f(brief_path(lane["repo_root"], lane["name"]))
    end

    # A name resolves to this repo's lane first, then to the only lane
    # anywhere that is in flight (those names are unique, #89), then to the
    # only open one, then to the only one.
    def resolve(name, from: Dir.pwd)
      root = main_root(from)
      lane = root && load(root, name)
      return lane if lane

      matches = all.select { |candidate| candidate["name"] == name }
      raise OptionParser::InvalidArgument, "no lane named #{name.inspect} (see `harnex lanes`)" if matches.empty?

      [matches.select { |l| in_flight?(l) }, matches.select { |l| open?(l) }, matches].each do |group|
        return group.first if group.one?
      end
      raise OptionParser::InvalidArgument,
            "several lanes are named #{name.inspect} (#{matches.map { |l| l['repo_root'] }.join(', ')}); run from the lane's repo"
    end

    # Working (or finished but uncollected), or a worktree not yet landed,
    # in a repo that still exists.
    def in_flight?(lane)
      open?(lane) && !never_started?(lane) && (lane["state"] == "running" || !lane["branch"].nil?) &&
        File.directory?(lane["repo_root"].to_s)
    end

    # #89: the in-flight lane anywhere that holds `name`, if any. A name is
    # free only when no repo has it in flight, so `harnex result NAME` and
    # `reply NAME` find their lane from anywhere.
    def holder(name)
      all.find { |lane| lane["name"] == name && in_flight?(lane) }
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
                our my me i we gpt worker workers task repo repository git command file files code
                are is be carry out brief lane].freeze

    # A lane working in another worktree of the repo is named after that
    # worktree (`pi-night-1024_s3`); otherwise after the task's first words.
    # Either way no repo has the name in flight (#89).
    def generate_name(root, task, cwd: nil, prefix: "pi")
      base = ([prefix] + name_words(root, task, cwd)).join("-")[0, 40].sub(/[-_.]+\z/, "")
      name = base
      index = 2
      while open?(load(root, name)) || holder(name) || Harnex.read_registry(root, name)
        name = "#{base}-#{index}"
        index += 1
      end
      name
    end

    def name_words(root, task, cwd)
      top = cwd && toplevel(cwd)
      if top && root && !same_dir?(top, root)
        slug = File.basename(top).downcase.gsub(/[^a-z0-9._-]+/, "-").sub(/\A[^a-z0-9]+/, "")
        return [slug] unless slug.empty?
      end
      task.to_s.downcase.scan(/[a-z0-9]+/).reject { |word| FILLER.include?(word) || word.match?(/\A[a-z]\z/) }.first(4)
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
    # of its worktrees), or nil outside git. In a bare layout (`repo/.bare`
    # plus sibling worktrees, #89) it is the worktree on the bare repo's HEAD
    # branch, so every worktree of the repo shares one lane namespace.
    def main_root(path)
      common, _err, ok = git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")
      return nil unless ok

      return File.dirname(common) if File.basename(common) == ".git"

      bare_main_worktree(path, common) || toplevel(path)
    end

    def same_dir?(one, two)
      File.realpath(one.to_s) == File.realpath(two.to_s)
    rescue SystemCallError
      File.expand_path(one.to_s) == File.expand_path(two.to_s)
    end

    def toplevel(path)
      top, _err, ok = git(path, "rev-parse", "--show-toplevel")
      ok ? top : nil
    end

    def bare_main_worktree(path, common)
      list, _err, ok = git(path, "worktree", "list", "--porcelain")
      return nil unless ok

      entries = list.split(/\n{2,}/).map do |block|
        block.lines.to_h { |line| line.chomp.split(" ", 2).then { |key, value| [key, value.to_s] } }
      end
      return nil unless entries.first&.key?("bare")

      head, _err, ok = git(common, "symbolic-ref", "-q", "HEAD")
      main = ok && entries.find { |entry| entry["branch"] == head && File.directory?(entry["worktree"].to_s) }
      main ? main["worktree"] : nil
    end

    def head_sha(dir)
      sha, _err, ok = git(dir, "rev-parse", "HEAD")
      ok ? sha : nil
    end

    def dirty_paths(dir)
      out, _err, ok = git(dir, "status", "--porcelain")
      ok ? out.lines.map { |line| line[3..].to_s.strip } : []
    end

    # #90: a worktree lane lives at .harnex/worktrees/NAME on harnex/NAME,
    # unless the repo's .harnex/config.json `lanes` templates say otherwise
    # ({name}, {yyyy}, {mm}, {dd}; worktree_path is relative to the main
    # checkout, so "../{name}" puts lanes beside it).
    def worktree_layout(root, name, now: Time.now)
      templates = Config.load_repo(root).lanes || {}
      fill = lambda do |template|
        template.gsub("{name}", name).gsub("{yyyy}", now.strftime("%Y")).gsub("{mm}", now.strftime("%m"))
                .gsub("{dd}", now.strftime("%d"))
      end
      path = fill.call(templates["worktree_path"] || File.join(WORKTREES_DIR, "{name}"))
      [File.expand_path(path, root), fill.call(templates["branch"] || "#{BRANCH_PREFIX}{name}")]
    rescue Config::ConfigError => e
      raise OptionParser::InvalidArgument, "invalid config #{e.message}"
    end

    def create_worktree(root, name)
      Harnex.ensure_git_excluded(root)
      worktree, branch = worktree_layout(root, name)
      _out, _err, valid = git(root, "check-ref-format", "--branch", branch)
      raise OptionParser::InvalidArgument, "lanes.branch gives #{branch.inspect}, which is not a valid branch name" unless valid

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

        forget(lane)
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

    # Inside the checkout: "a/b"; beside it: "../x"; anywhere else: absolute.
    def relative(root, path)
      return path.to_s.delete_prefix("#{root}/") if path.to_s.start_with?("#{root}/")

      sibling = "../#{File.basename(path.to_s)}"
      File.expand_path(sibling, root.to_s) == File.expand_path(path.to_s) ? sibling : path.to_s
    end

    # ---- briefs ------------------------------------------------------------

    def brief_path(repo_root, name)
      File.join(dir, "briefs", "#{Harnex.repo_key(repo_root)}--#{name}.md")
    end

    def write_brief(lane, task)
      file = brief_path(lane["repo_root"], lane["name"])
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
      before = lane.slice(*RELAUNCH_KEYS)
      lane["launched_at"] = now
      lane["state"] = "running"
      lane.delete("after_seq")
      lane.delete("last_error")
      save(lane)

      argv = harnex_command + ["run", "pi", "--id", lane["name"]]
      argv += detach ? ["--detach"] : ["--tmux", lane["name"]]
      argv += ["--cwd", lane["cwd"], "--root", lane["run_root"], "--auto-stop", "--intent", lane["kind"],
               "--phase", lane["phase"] || lane["kind"]]
      argv += context_args
      argv += ["--model", lane["requested_model"]] if lane["requested_model"]
      argv += ["--effort", lane["effort"]] if lane["effort"]
      argv += ["--wait-done"] + (timeout ? ["--wait-timeout", timeout.to_s] : []) if wait
      argv += ["--"] + child_args unless child_args.empty?
      stdout, stderr, status = Open3.capture3(*argv)
      payload = last_json(stdout)
      if payload.empty?
        # 124: the worker did not register in time and may still come up.
        status.exitstatus == Waiter::DONE_EXIT_TIMEOUT ? fail_launch(lane, stderr) : unlaunch(lane, before)
        raise LaunchError, "harnex could not start lane #{lane['name']}: #{stderr.strip.lines.last(3).join.strip}"
      end
      return [payload, 0] unless wait

      [payload["turn_result"] || payload, status.exitstatus]
    end

    RELAUNCH_KEYS = %w[state launched_at after_seq last_error].freeze

    # A launch refused before the worker started (a bad flag, repo phase
    # policy, a busy id) leaves no trace: a new lane's record goes, and a
    # resumed lane keeps what its last turn left.
    def unlaunch(lane, before)
      return forget(lane) if lane["turns"].to_i.zero?

      RELAUNCH_KEYS.each { |key| before.key?(key) ? lane[key] = before[key] : lane.delete(key) }
      save(lane)
    end

    def fail_launch(lane, stderr)
      lane["state"] = "failed"
      lane["last_error"] = stderr.strip.lines.last.to_s.strip
      save(lane)
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
                                     "outcome_class", "status", "last_error", "end_sha", "earlier_replies")
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
      message = with_earlier_replies(final_message(turn), turn)
      lines << message.rstrip << "" unless message.strip.empty? || exit_code == Waiter::DONE_EXIT_TIMEOUT
      lines << "── #{lane['name']}: #{headline(lane, turn, exit_code)}"
      lines.concat((interjection_lines(lane) + details(lane, exit_code)).map { |line| "   #{line}" })
      lines.join("\n")
    end

    # An answered ask prints only its answer, plus what else reached the
    # worker (#92).
    def render_answer(lane, turn)
      text = with_earlier_replies(final_message(turn), turn)
      notes = interjection_lines(lane)
      return text if notes.empty?

      [text.rstrip, "", "── #{lane['name']}: #{notes.first}", *notes.drop(1).map { |line| "   #{line}" }].join("\n")
    end

    # #92: when a later message reached the worker after it had answered,
    # the turn's result is its answer to that message; the answers it
    # replaced (the original task's report among them) come first.
    def with_earlier_replies(message, turn)
      earlier = Array(turn["earlier_replies"]).map(&:to_s).reject { |text| text.strip.empty? }
      return message if earlier.empty? || message.strip.empty?

      parts = earlier.map { |text| "[earlier reply this turn, before another message reached the worker]\n#{text.rstrip}" }
      (parts + ["[latest reply]\n#{message.rstrip}"]).join("\n\n")
    end

    # #92: messages that reached the worker from anyone but the lane's own
    # owner and its `harnex reply` (someone's `harnex send` from another
    # terminal or session), since the lane's latest launch.
    def interjections(lane)
      events(lane).select do |event|
        event["type"] == "send" && event["from"].is_a?(Hash) && after?(event["ts"], lane["launched_at"]) &&
          !own_message?(lane, event["from"])
      end
    end

    def own_message?(lane, from)
      owner = lane["owner"].to_s
      from["owner"].to_s == owner && (!owner.empty? || from["via"] == "reply")
    end

    def interjection_lines(lane)
      found = interjections(lane)
      return [] if found.empty?

      count = found.length == 1 ? "1 message" : "#{found.length} messages"
      ["interjected: #{count} reached the worker from outside this lane " \
       "(the reply above may answer #{found.length == 1 ? 'it' : 'them'}; all: `harnex events --id #{lane['name']}`):"] +
        found.last(5).map { |event| "  #{clock(event['ts'])} #{sender_label(event['from'])}: #{preview(event)}" }
    end

    def sender_label(from)
      who = if from["session"] then "harnex session #{from['session']}"
            elsif from["owner"] then "session #{from['owner'][0, 8]}"
            else "a terminal"
            end
      "from #{who} (harnex #{from['via'] || 'send'})"
    end

    def preview(event)
      text = event["msg"].to_s.sub(/\A\[harnex [^\]]*\]\s*/, "").gsub(/\s+/, " ").strip
      cut = text.length > 160 || event["msg_truncated"]
      "\"#{text[0, 160]}#{cut ? '…' : ''}\""
    end

    def clock(ts)
      Time.iso8601(ts.to_s).localtime.strftime("%H:%M:%S")
    rescue ArgumentError
      ts.to_s
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

      shas = lane["branch"] ? nil : worker_commits(lane)
      return worker_change_summary(lane, dir, shas) if shas

      count, _err, ok = git(dir, "rev-list", "--count", "#{lane['base_sha']}..HEAD")
      return nil unless ok

      stat, = git(dir, "diff", "--shortstat", lane["base_sha"], "HEAD")
      commits = "#{count} commit#{count == '1' ? '' : 's'}"
      stat.empty? ? commits : "#{commits}, #{compact_stat(stat)}"
    end

    # #91: a lane working in place shares HEAD with whoever else commits
    # there, so count only the commits the worker made (worker_commits
    # events). nil when the worker's harnex did not track them.
    def worker_commits(lane)
      found = events(lane).select { |event| after?(event["ts"], lane["created_at"]) }
      return nil unless found.any? { |event| event["type"] == "git" && event["tracks_worker_commits"] }

      found.select { |event| event["type"] == "worker_commits" }.flat_map { |event| Array(event["shas"]) }
    end

    def worker_change_summary(lane, dir, shas)
      moved, _err, ok = git(dir, "rev-list", "#{lane['base_sha']}..HEAD")
      return nil unless ok

      history = moved.split
      mine = history & shas
      text = "#{mine.length} commit#{mine.length == 1 ? '' : 's'}"
      stat = mine.empty? ? nil : commits_stat(dir, mine)
      text += ", #{stat}" if stat
      others = history.length - mine.length
      text += " (HEAD also moved #{others} commit#{others == 1 ? '' : 's'} by others)" if others.positive?
      text
    end

    def commits_stat(dir, shas)
      out, _err, ok = git(dir, "show", "--numstat", "--format=", *shas)
      return nil unless ok

      files = {}
      added = removed = 0
      out.each_line do |line|
        plus, minus, path = line.chomp.split("\t", 3)
        next unless path

        files[path] = true
        added += plus.to_i
        removed += minus.to_i
      end
      "#{files.size} file#{files.size == 1 ? '' : 's'} (+#{added} -#{removed})"
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
