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

        Ask a Pi worker one question and print its answer on stdout. The worker
        runs in a visible tmux window, reads the repository, and stops when it
        has answered. stderr gets one line naming the lane, its time and model.
        A read-only ask records its dispatch in the global harnex stream, so the
        repository stays untouched; --write records in the repository.

        Options:
          --model NAME     Pi model (provider/model); default: Pi's own default
                           (`defaultProvider`/`defaultModel` in ~/.pi/agent/settings.json)
          --fallback-model NAME
                           Ask once more with NAME when the first model fails on
                           provider capacity or rate limits (provider_capacity)
          --effort LEVEL   Reasoning effort / Pi thinking level
          --cwd DIR        Directory the worker works in (default: current directory)
          --file PATH      Read the question from PATH (see run --context-file)
          --section TEXT   With --file: send only that section
          --write          Let the worker edit files and run commands (default:
                           read-only tools #{READ_ONLY_TOOLS})
          --id ID          Session id (default: pi-ask-<random>)
          --timeout DUR    Cap the wait: 540, 9m or 8m30s (default: none). On 124
                           stderr names the command that keeps waiting
          --detach         Run headless instead of in a tmux window
          --json           Print the full result JSON instead of the answer
          -h, --help       Show this help

        Exit codes: 0 answered, 1 the worker failed (stderr says why), 2 proof
        rejected or a usage error (usage errors print no JSON and no answer),
        124 timeout (the worker keeps running).

        Examples:
          harnex ask "Which module parses the dispatch rows, and is it tested?"
          harnex ask --model foundry-zyt/gpt-6.1-sol --file /tmp/review.md --timeout 9m
          harnex ask --write --cwd ../lane "Fix the failing test and commit"
      TEXT
    end

    def initialize(argv, out: $stdout, err: $stderr, harnex_command: nil)
      @argv = argv.dup
      @out = out
      @err = err
      @harnex_command = harnex_command || [Gem.ruby, File.expand_path("../../../bin/harnex", __dir__)]
      @options = { model: nil, fallback_model: nil, effort: nil, cwd: nil, file: nil, section: nil, write: false,
                   id: nil, timeout: nil, detach: false, json: false, help: false }
    end

    def run
      question = parse
      if @options[:help]
        @out.puts self.class.usage
        return 0
      end
      if question.empty? && @options[:file].nil?
        raise OptionParser::MissingArgument, "QUESTION (or --file PATH)"
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result, exit_code = ask_once(question, @options[:model], @options[:id])
      if exit_code == 1 && @options[:fallback_model] && result.dig("turn_result", "outcome_class") == "provider_capacity"
        @err.puts("harnex ask: #{result['id']} hit provider capacity; asking #{@options[:fallback_model]} instead")
        retry_id = @options[:id] && "#{@options[:id]}-fallback"
        result, exit_code = ask_once(question, @options[:fallback_model], retry_id)
      end
      report(result, exit_code, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
    end

    private

    def ask_once(question, model, id)
      stdout, status = launch(question, model, id)
      [parse_result(stdout), status.exitstatus]
    end

    def launch(question, model, id)
      id ||= "pi-ask-#{SecureRandom.hex(2)}"
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
      argv += ["--auto-stop", "--wait-done", "--intent", INTENT]
      argv += ["--wait-timeout", @options[:timeout].to_s] if @options[:timeout]
      argv += ["--model", model] if model
      argv += ["--effort", @options[:effort]] if @options[:effort]
      argv += ["--", "--no-approve"]
      argv += ["--tools", READ_ONLY_TOOLS] unless @options[:write]
      stdout, status = Open3.capture2(*argv)
      [stdout, status]
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
        @err.puts("harnex ask: #{result['id']} is still working; keep waiting with: #{result['resume']}")
      else
        @out.puts answer unless answer.to_s.empty?
        reason = turn["last_error"] || turn["outcome_class"] || result["error"] || "no result"
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
        when "--model", "--effort", "--cwd", "--file", "--section", "--id", "--fallback-model"
          @options[arg.delete_prefix("--").tr("-", "_").to_sym] = value(index += 1, arg)
        when "--timeout"
          @options[:timeout] = Harnex.parse_duration_seconds(value(index += 1, arg), option_name: arg)
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

      question.join(" ")
    end

    def value(index, name)
      value = @argv[index]
      raise OptionParser::MissingArgument, name if value.nil? || value.start_with?("--")

      value
    end
  end
end
