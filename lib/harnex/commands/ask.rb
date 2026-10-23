require "fileutils"
require "json"
require "open3"
require "securerandom"
require "shellwords"

module Harnex
  # `harnex ask` (#85): hand one question to a Pi worker (a GPT or other
  # provider model) and print its answer, so a Claude session consults
  # another model the way it calls any tool. Read-only by default; the
  # dispatch is a normal harnex run (tmux window, receipt, dispatch rows).
  class Ask
    READ_ONLY_TOOLS = "read,grep,find,ls".freeze
    INTENT = "ask".freeze

    def self.usage
      <<~TEXT
        Usage: harnex ask [options] [--] QUESTION...
               harnex ask --file PATH [--section TEXT] [options]
               harnex ask --resume ID [--timeout DUR] [--json]

        Ask a Pi worker one question and print its answer on stdout. The worker
        runs in a visible tmux window, reads the repository (it cannot run
        commands unless --write; to run things use `harnex delegate`), and stops
        when it has answered. stderr gets one line naming the lane, its time and model.
        A read-only ask records its dispatch in the global harnex stream, so the
        repository stays untouched; --write records in the repository.

        Options:
          --model NAME     Pi model (provider/model); default: Pi's own default
                           (`defaultProvider`/`defaultModel` in ~/.pi/agent/settings.json)
          --fallback-model NAME
                           Ask once more with NAME when the first model fails on
                           provider capacity or rate limits (provider_capacity)
          --effort LEVEL   Reasoning effort / Pi thinking level
          --phase NAME     Tag the run with a repo work phase (with --write, checked
                           against the repo's allowlist); default: ask
          --cwd DIR        Directory the worker works in (default: current directory)
          --file PATH      Read the question from PATH (see run --context-file)
          --section TEXT   With --file: send only that section
          --write          Let the worker edit files and run commands (default:
                           read-only tools #{READ_ONLY_TOOLS})
          --id ID          Session id (default: pi-ask-<random>)
          --timeout DUR    Cap the wait: 540, 9m or 8m30s (default 9m; `none` waits
                           without a cap). On 124 the worker keeps going and stderr
                           names the command that keeps waiting (`harnex result ID`)
          --resume ID      Same as `harnex result ID` (kept for older callers)
          --detach         Run headless instead of in a tmux window
          --json           Print the full result JSON instead of the answer
          -h, --help       Show this help

        Exit codes: 0 answered, 1 the worker failed (stderr says why), 2 proof
        rejected or a usage error (usage errors print no JSON and no answer),
        124 timeout (the worker keeps running).

        Examples:
          harnex ask "Which module parses the dispatch rows, and is it tested?"
          harnex ask --model openai/gpt-5.1 --file /tmp/review.md --timeout 9m
          harnex ask --write --cwd ../lane "Fix the failing test and commit"
      TEXT
    end

    def initialize(argv, out: $stdout, err: $stderr, harnex_command: nil)
      @argv = argv.dup
      @out = out
      @err = err
      @harnex_command = harnex_command || [Gem.ruby, File.expand_path("../../../bin/harnex", __dir__)]
      @options = { model: nil, fallback_model: nil, effort: nil, phase: nil, cwd: nil, file: nil, section: nil, write: false,
                   id: nil, timeout: Lanes::DEFAULT_TIMEOUT, detach: false, json: false, help: false, resume: nil,
                   repo: nil }
    end

    def run
      question = parse
      if @options[:help]
        @out.puts self.class.usage
        return 0
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return report(*resume_once(@options[:resume]), Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) if @options[:resume]

      if question.empty? && @options[:file].nil?
        raise OptionParser::MissingArgument, "QUESTION (or --file PATH)"
      end

      result, exit_code = ask_once(question, @options[:model], @options[:id])
      if exit_code == 1 && @options[:fallback_model] && result.dig("turn_result", "outcome_class") == "provider_capacity"
        @err.puts("harnex ask: #{result['id']} hit provider capacity; asking #{@options[:fallback_model]} instead")
        retry_id = @options[:id] && "#{@options[:id]}-fallback"
        result, exit_code = ask_once(question, @options[:fallback_model], retry_id)
      end
      report(result, exit_code, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
    end

    private

    # Each ask is a lane (#87), so `harnex result ID` keeps waiting on it and
    # `harnex reply ID "..."` follows up with the worker's context.
    def ask_once(question, model, id)
      id ||= "pi-ask-#{SecureRandom.hex(2)}"
      lane = register_lane(id, model)
      stdout, status = launch(question, model, id)
      result = parse_result(stdout)
      if !result.empty?
        Lanes.settle(lane, result["turn_result"] || {}, status.exitstatus)
      elsif status.exitstatus != Waiter::DONE_EXIT_TIMEOUT
        # Refused before the worker started (#88); 124 may still come up.
        Lanes.forget(lane)
      end
      [result, status.exitstatus]
    end

    def register_lane(id, model)
      cwd = File.expand_path(@options[:cwd] || Dir.pwd)
      Lanes.save(
        "name" => id, "kind" => "ask", "repo_root" => Lanes.main_root(cwd) || cwd, "run_root" => run_root,
        "cwd" => cwd, "read_only" => !@options[:write], "owner" => Harnex.ambient_owner_id,
        "requested_model" => model, "effort" => @options[:effort], "phase" => @options[:phase],
        "created_at" => Lanes.now, "launched_at" => Lanes.now, "state" => "running", "turns" => 0
      )
    end

    def launch(question, model, id)
      argv = @harnex_command + ["run", "pi", "--id", id]
      argv += @options[:detach] ? ["--detach"] : ["--tmux", id]
      argv += ["--cwd", File.expand_path(@options[:cwd] || Dir.pwd)]
      # A consult is not repository work: register and record it under a
      # harnex-owned root (not a git repo, so rows go to the global stream).
      argv += ["--root", ask_root] unless @options[:write]
      if @options[:file]
        argv += ["--context-file", @options[:file]]
        argv += ["--context-section", @options[:section]] if @options[:section]
      else
        argv += ["--context", question]
      end
      argv += ["--auto-stop", "--wait-done", "--intent", INTENT, "--phase", @options[:phase] || INTENT]
      argv += ["--wait-timeout", @options[:timeout].to_s] if @options[:timeout]
      argv += ["--model", model] if model
      argv += ["--effort", @options[:effort]] if @options[:effort]
      argv += ["--", "--no-approve"]
      argv += ["--tools", READ_ONLY_TOOLS] unless @options[:write]
      stdout, status = Open3.capture2(*argv)
      [stdout, status]
    end

    # A subagent's Bash call is capped at 10 minutes, so a long ask comes back
    # 124 and the caller re-runs this until the answer lands. `wait` prints the
    # turn result unnested; nest it so the answer is reported like a fresh ask.
    def resume_once(id)
      lane = begin
        Lanes.resolve(id)
      rescue OptionParser::InvalidArgument
        nil
      end
      return legacy_resume(id) unless lane
      return [{ "id" => id, "turn_result" => lane["last_turn"] || {} }, lane["state"] == "failed" ? 1 : 0] unless lane["state"] == "running"

      turn, exit_code = Lanes.wait(lane, @harnex_command, timeout: @options[:timeout])
      Lanes.settle(lane, turn, exit_code || 1)
      [{ "id" => id, "turn_result" => turn }, exit_code || 1]
    end

    # Asks from before lanes (0.21.0) have no record; their resume line named --repo.
    def legacy_resume(id)
      raise OptionParser::InvalidArgument, "no lane named #{id.inspect}" unless @options[:repo]

      argv = @harnex_command + ["wait", "--id", id, "--repo", @options[:repo], "--until", "done"]
      argv += ["--timeout", @options[:timeout].to_s] if @options[:timeout]
      stdout, status = Open3.capture2(*argv)
      [{ "id" => id, "turn_result" => parse_result(stdout) }, status.exitstatus]
    end

    def resume_command(id)
      "#{Harnex.cli_command} result #{id}"
    end

    # The root `run` records under: ask_root for a consult, the work
    # directory for --write (run takes --cwd as the root when --root is absent).
    def run_root
      return @options[:repo] if @options[:resume]

      @options[:write] ? File.expand_path(@options[:cwd] || Dir.pwd) : ask_root
    end

    def parse_result(stdout)
      JSON.parse(stdout.to_s.lines.last.to_s)
    rescue JSON::ParserError
      {}
    end

    def ask_root
      root = File.join(Harnex::STATE_DIR, "ask")
      FileUtils.mkdir_p(root)
      root
    end

    def report(result, exit_code, elapsed)
      if @options[:json]
        @out.puts JSON.generate(result) unless result.empty?
        return exit_code
      end

      turn = result["turn_result"] || {}
      answer = full_answer(turn)
      case exit_code
      when 0
        @out.puts answer.to_s
        @err.puts("harnex ask: #{result['id']} answered in #{elapsed.round}s (model #{turn['model'] || 'Pi default'})")
      when Waiter::DONE_EXIT_TIMEOUT
        @err.puts("harnex ask: #{result['id']} is still working; keep waiting with: #{resume_command(result['id'])}")
      else
        @out.puts answer unless answer.to_s.empty?
        reason = turn["last_error"] || turn["outcome_class"] || turn["status"] || result["error"] || "no result"
        @err.puts("harnex ask: #{result['id'] || 'the worker'} did not answer (#{reason})")
      end
      exit_code
    end

    def full_answer(turn)
      path = turn["final_message_path"].to_s
      return File.read(path).chomp if turn["final_message_truncated"] && !path.empty? && File.file?(path)

      turn["final_message"]
    rescue StandardError
      turn["final_message"]
    end

    def parse
      question = []
      index = 0
      while index < @argv.length
        arg = @argv[index]
        case arg
        when "--"
          question.concat(@argv[(index + 1)..] || [])
          break
        when "-h", "--help" then @options[:help] = true
        when "--write" then @options[:write] = true
        when "--detach" then @options[:detach] = true
        when "--json" then @options[:json] = true
        when "--model", "--effort", "--phase", "--cwd", "--file", "--section", "--id", "--fallback-model", "--resume", "--repo"
          @options[arg.delete_prefix("--").tr("-", "_").to_sym] = value(index += 1, arg)
        # Habits from `harnex run` (#87): an ask already runs in a tmux window
        # named after its id and stops after answering.
        when "--tmux"
          following = @argv[index + 1]
          if following&.match?(Lanes::NAME) && !following.start_with?("-") && @argv.length > index + 2
            @options[:id] ||= following
            index += 1
          end
        when "--auto-stop", "--wait-done" then nil
        when "--wait-timeout"
          @options[:timeout] = Lanes.parse_timeout(value(index += 1, arg), option_name: arg)
        when "--context" then question << value(index += 1, arg)
        when "--context-file" then @options[:file] = value(index += 1, arg)
        when "--timeout"
          @options[:timeout] = Lanes.parse_timeout(value(index += 1, arg), option_name: arg)
        when /\A--/
          raise OptionParser::InvalidOption, "harnex ask: unknown flag #{arg}; see harnex ask --help"
        else
          question << arg
        end
        index += 1
      end
      if @options[:section] && @options[:file].nil?
        raise OptionParser::InvalidOption, "harnex ask: --section requires --file"
      end
      if @options[:resume] && (!question.empty? || @options[:file])
        raise OptionParser::InvalidOption, "harnex ask: --resume takes a lane id and no question"
      end
      if @options[:repo] && @options[:resume].nil?
        raise OptionParser::InvalidOption, "harnex ask: --repo requires --resume"
      end

      question.join(" ")
    end

    def value(index, name)
      value = @argv[index]
      raise OptionParser::MissingArgument, name if value.nil? || value.start_with?("--")

      value
    end
  end
end
