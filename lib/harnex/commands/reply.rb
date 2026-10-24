module Harnex
  # `harnex reply` (#87): send a lane more work. A worker still on its turn
  # takes the message as a follow-up; a lane that has finished is relaunched
  # on its own Pi session, so the worker keeps everything it knew.
  class Reply
    def self.usage
      <<~TEXT
        Usage: harnex reply NAME [options] [--] MESSAGE...

        Send a lane a follow-up and print the result, in the same format as
        `harnex delegate`. The worker keeps its context: a busy worker gets the
        message during its turn; a finished lane resumes its Pi session.

        Options:
          --model NAME    Model for this turn (default: the lane's)
          --no-wait       Send and return at once; collect with `harnex result NAME`
          --timeout DUR   Wait at most DUR (default 9m; `none` waits without a cap)
          --json          Print the lane record and result as JSON
          -h, --help      Show this help

        Exit codes: 0 done, 1 failed, 2 usage error, 124 still working.
      TEXT
    end

    def initialize(argv, out: $stdout, err: $stderr, harnex_command: nil)
      @argv = argv.dup
      @out = out
      @err = err
      @harnex_command = harnex_command || [Gem.ruby, File.expand_path("../../../bin/harnex", __dir__)]
      @options = { model: nil, wait: true, timeout: Lanes::DEFAULT_TIMEOUT, json: false, help: false }
    end

    def run
      name, message = parse
      if @options[:help]
        @out.puts self.class.usage
        return 0
      end
      raise OptionParser::MissingArgument, "NAME" if name.nil?
      raise OptionParser::MissingArgument, "MESSAGE" if message.strip.empty?

      lane = Lanes.resolve(name)
      unless Lanes.open?(lane)
        raise OptionParser::InvalidArgument, "lane #{name} was #{lane['state']}; start a new one with `harnex delegate`"
      end

      lane["requested_model"] = @options[:model] if @options[:model]
      turn, exit_code = Lanes.live?(lane) ? follow_up(lane, message) : relaunch(lane, message)
      return sent(lane) unless @options[:wait]

      lane = Lanes.settle(lane, turn, exit_code)
      @out.puts(@options[:json] ? JSON.generate(lane: lane, result: turn, exit_code: exit_code) : Lanes.render(lane, turn, exit_code))
      exit_code
    rescue Lanes::LaunchError => e
      @err.puts(e.message)
      1
    end

    private

    def follow_up(lane, message)
      argv = @harnex_command + ["send", "--id", lane["name"], "--repo", lane["run_root"], "--message", message]
      argv += ["--wait-done"] + (@options[:timeout] ? ["--timeout", @options[:timeout].to_s] : []) if @options[:wait]
      # Marked as the lane's own follow-up, not an interjection (#92).
      stdout, stderr, status = Open3.capture3({ "HARNEX_SEND_VIA" => "reply" }, *argv)
      result = Lanes.last_json(stdout)
      raise Lanes::LaunchError, "harnex could not reach lane #{lane['name']}: #{stderr.strip.lines.last}" if result.empty?

      # The lane's turn is out again; `result` waits for the turn this
      # message started or joined.
      lane["state"] = "running"
      lane["after_seq"] = result["after_seq"] if result["after_seq"]
      Lanes.save(lane)
      [result, status.exitstatus]
    end

    def relaunch(lane, message)
      child_args = []
      child_args += ["--session", lane["agent_session_id"]] if lane["agent_session_id"]
      child_args += ["--tools", Ask::READ_ONLY_TOOLS] if lane["read_only"]
      unless lane["agent_session_id"]
        @err.puts("harnex reply: no Pi session recorded for #{lane['name']}; the worker starts without its earlier context")
      end
      Lanes.launch(lane, @harnex_command, context_args: ["--context", message], child_args: child_args,
                                          wait: @options[:wait], timeout: @options[:timeout])
    end

    def sent(lane)
      @out.puts(@options[:json] ? JSON.generate(lane) : "── #{lane['name']}: message sent; collect: harnex result #{lane['name']}")
      0
    end

    def parse
      words = []
      index = 0
      while index < @argv.length
        arg = @argv[index]
        case arg
        when "--"
          words.concat(@argv[(index + 1)..] || [])
          break
        when "-h", "--help" then @options[:help] = true
        when "--no-wait" then @options[:wait] = false
        when "--json" then @options[:json] = true
        when "--model"
          @options[:model] = @argv[index += 1] || raise(OptionParser::MissingArgument, arg)
        when "--timeout", "--wait-timeout"
          @options[:timeout] = Lanes.parse_timeout(@argv[index += 1] || raise(OptionParser::MissingArgument, arg))
        when "--id"
          @options[:name] = @argv[index += 1] || raise(OptionParser::MissingArgument, arg)
        when "--message"
          @options[:message] = @argv[index += 1] || raise(OptionParser::MissingArgument, arg)
        when "--wait-done", "--tmux" then nil
        when /\A--/
          raise OptionParser::InvalidOption, "harnex reply: unknown flag #{arg}; see harnex reply --help"
        else
          words << arg
        end
        index += 1
      end
      words.unshift(@options[:name]) if @options[:name]
      words << @options[:message] if @options[:message]
      [words.first, words.drop(1).join(" ")]
    end
  end
end
