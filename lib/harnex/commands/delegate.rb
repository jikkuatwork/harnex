module Harnex
  # `harnex delegate` (#87): hand one task to a Pi worker and print its
  # reply plus a lane footer (state, time, model, cost, commits, next
  # commands). With --worktree NAME the worker gets its own git worktree on
  # branch harnex/NAME, so parallel lanes never touch the main checkout.
  class Delegate
    def self.usage
      <<~TEXT
        Usage: harnex delegate [options] [--] TASK...
               harnex delegate --file PATH [options]

        Hand a task to a Pi worker (a GPT model by default) and print its reply
        and a lane summary. The worker runs in a visible tmux window, may edit
        files and run commands, and stops when it has replied. Follow up with
        `harnex reply NAME "..."`; it keeps the worker's context.

        Options:
          --worktree NAME  Work in a new git worktree (.harnex/worktrees/NAME, branch
                           harnex/NAME); finish with `harnex land NAME` or
                           `harnex discard NAME`
          --name NAME      Lane name without a worktree (default: from the task)
          --cwd DIR        Directory the worker works in (default: current directory)
          --file PATH      Read the task from PATH
          --model NAME     Pi model (provider/model); default: Pi's own default
          --effort LEVEL   Reasoning effort / Pi thinking level
          --phase NAME     Tag the run with a repo work phase (checked against the
                           repo's .harnex/config.json allowlist); default: delegate,
                           which every allowlist accepts
          --no-wait        Start the lane and return at once; collect with
                           `harnex result` (all your lanes) or `harnex result NAME`
          --timeout DUR    Wait at most DUR (default 9m, fits a 10-minute tool cap;
                           `none` waits without a cap). On 124 the worker keeps going:
                           run `harnex result NAME`
          --detach         Run headless instead of in a tmux window
          --json           Print the lane record and result as JSON
          -h, --help       Show this help

        Exit codes: 0 done, 1 failed, 2 usage error, 124 still working.

        Examples:
          harnex delegate --worktree word-count "Add TextKit.word_count with a test"
          harnex delegate --no-wait --worktree fix-a "Fix A"   # then: harnex result
          harnex delegate "Run bin/slow-bench and report the score"
      TEXT
    end

    def initialize(argv, out: $stdout, err: $stderr, harnex_command: nil)
      @argv = argv.dup
      @out = out
      @err = err
      @harnex_command = harnex_command || [Gem.ruby, File.expand_path("../../../bin/harnex", __dir__)]
      @options = { worktree: nil, name: nil, cwd: nil, file: nil, model: nil, effort: nil, phase: nil, wait: true,
                   timeout: Lanes::DEFAULT_TIMEOUT, detach: false, json: false, help: false }
    end

    def run
      task = parse
      if @options[:help]
        @out.puts self.class.usage
        return 0
      end
      task = File.read(@options[:file]) if task.empty? && @options[:file]
      raise OptionParser::MissingArgument, "TASK (or --file PATH)" if task.strip.empty?

      lane = @lane = build_lane(task)
      brief = Lanes.write_brief(lane, task)
      turn, exit_code = Lanes.launch(lane, @harnex_command, context_args: ["--context-file", brief],
                                                            wait: @options[:wait], timeout: @options[:timeout],
                                                            detach: @options[:detach])
      return started(lane) unless @options[:wait]

      lane = Lanes.settle(lane, turn, exit_code)
      report(lane, turn, exit_code)
    rescue Lanes::LaunchError => e
      discard_unstarted
      @err.puts(e.message)
      1
    end

    private

    def build_lane(task)
      workdir = File.expand_path(@options[:cwd] || Dir.pwd)
      raise OptionParser::InvalidArgument, "--cwd #{workdir} is not a directory" unless File.directory?(workdir)

      root = Lanes.main_root(workdir)
      raise OptionParser::InvalidArgument, "--worktree needs a git repository (#{workdir} is not in one)" if @options[:worktree] && root.nil?

      Lanes.sweep_merged(root)
      root ||= workdir
      name = Lanes.validate_name!(@options[:worktree] || @options[:name] || Lanes.generate_name(root, task))
      ensure_free!(root, name)
      lane = {
        "name" => name, "kind" => "delegate", "repo_root" => root, "run_root" => root, "cwd" => workdir,
        "owner" => Harnex.ambient_owner_id, "requested_model" => @options[:model], "effort" => @options[:effort],
        "phase" => @options[:phase], "created_at" => Lanes.now, "turns" => 0
      }
      if @options[:worktree]
        warn_uncommitted(root)
        lane["worktree"], lane["branch"], lane["base_sha"] = Lanes.create_worktree(root, name)
        lane["cwd"] = lane["worktree"]
      else
        Harnex.ensure_git_excluded(root) if Lanes.main_root(workdir)
        lane["base_sha"] = Lanes.head_sha(workdir)
      end
      lane
    end

    # A lane that never started leaves nothing behind.
    def discard_unstarted
      return unless @lane && @lane["turns"].to_i.zero?

      Lanes.remove_worktree(@lane, force: true) if @lane["worktree"]
      Lanes.forget(@lane)
    end

    def ensure_free!(root, name)
      existing = Lanes.load(root, name)
      if Lanes.never_started?(existing)
        Lanes.forget(existing)
        existing = nil
      end
      if Lanes.open?(existing)
        raise OptionParser::InvalidArgument,
              "lane #{name} already exists (#{existing['state']}): follow up with `harnex reply #{name} \"...\"`, " \
              "or `harnex land #{name}` / `harnex discard #{name}` first"
      end
      return unless Harnex.read_registry(root, name)

      raise OptionParser::InvalidArgument, "a harnex session named #{name} is running; pick another name"
    end

    def warn_uncommitted(root)
      dirty = Lanes.dirty_paths(root)
      return if dirty.empty?

      @err.puts("harnex delegate: the main checkout has #{dirty.length} uncommitted change(s); " \
                "the worktree starts from HEAD and won't see them")
    end

    def started(lane)
      if @options[:json]
        @out.puts JSON.generate(lane)
      else
        where = lane["worktree"] ? " in #{Lanes.relative(lane['repo_root'], lane['worktree'])}" : ""
        @out.puts "── #{lane['name']}: started#{where}"
        @out.puts "   collect: harnex result #{lane['name']}   (or `harnex result` for all your lanes)"
      end
      0
    end

    def report(lane, turn, exit_code)
      if @options[:json]
        @out.puts JSON.generate(lane: lane, result: turn, exit_code: exit_code)
      else
        @out.puts Lanes.render(lane, turn, exit_code)
      end
      exit_code
    end

    def parse
      task = []
      index = 0
      while index < @argv.length
        arg = @argv[index]
        case arg
        when "--"
          task.concat(@argv[(index + 1)..] || [])
          break
        when "-h", "--help" then @options[:help] = true
        when "--no-wait" then @options[:wait] = false
        when "--detach" then @options[:detach] = true
        when "--json" then @options[:json] = true
        when "--worktree", "--name", "--cwd", "--file", "--model", "--effort", "--phase"
          @options[arg.delete_prefix("--").to_sym] = value(index += 1, arg)
        when "--timeout", "--wait-timeout"
          @options[:timeout] = Lanes.parse_timeout(value(index += 1, arg))
        # Habits from `harnex run`: a lane already runs in a tmux window named
        # after it, stops after its reply and waits for it, so these are
        # accepted rather than refused.
        when "--id" then @options[:name] = value(index += 1, arg)
        when "--tmux" then index += 1 if lane_name_follows?(index) && (@options[:name] ||= @argv[index + 1])
        when "--auto-stop", "--wait-done" then nil
        when "--context" then task << value(index += 1, arg)
        when "--context-file" then @options[:file] = value(index += 1, arg)
        when /\A--/
          raise OptionParser::InvalidOption, "harnex delegate: unknown flag #{arg}; see harnex delegate --help"
        else
          task << arg
        end
        index += 1
      end
      task.join(" ")
    end

    def lane_name_follows?(index)
      following = @argv[index + 1]
      !following.nil? && following.match?(Lanes::NAME) && !following.start_with?("-")
    end

    def value(index, name)
      value = @argv[index]
      raise OptionParser::MissingArgument, name if value.nil? || value.start_with?("--")

      value
    end
  end
end
