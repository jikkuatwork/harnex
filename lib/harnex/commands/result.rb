module Harnex
  # `harnex result` (#87): block until lanes report and print each result as
  # it lands, in the same format as `delegate`. With no names it waits for
  # every lane this caller started in this repo that nobody has collected.
  class LaneResult
    def self.usage
      <<~TEXT
        Usage: harnex result [NAME...] [options]

        Wait for lanes to report and print each result as it lands. With no
        NAME: every lane you started in this repo whose result you have not
        collected yet (from `harnex delegate --no-wait`, a timed-out delegate,
        reply or ask).

        Options:
          --timeout DUR  Wait at most DUR (default 9m; `none` waits without a cap).
                         On 124 the workers keep going: run the same command again
          --json         One JSON line per lane instead of text
          -h, --help     Show this help

        Exit codes: 0 every lane done, 1 a lane failed, 124 a lane still working.
      TEXT
    end

    def initialize(argv, out: $stdout, err: $stderr, harnex_command: nil)
      @argv = argv.dup
      @out = out
      @err = err
      @harnex_command = harnex_command || [Gem.ruby, File.expand_path("../../../bin/harnex", __dir__)]
      @options = { timeout: Lanes::DEFAULT_TIMEOUT, json: false, help: false }
      @print_lock = Mutex.new
    end

    def run
      names = parse
      if @options[:help]
        @out.puts self.class.usage
        return 0
      end
      Lanes.sweep_merged(Lanes.main_root(Dir.pwd))
      lanes = names.empty? ? Lanes.pending : names.map { |name| Lanes.resolve(name) }
      if lanes.empty?
        @out.puts "no lanes waiting to be collected (see `harnex lanes`)"
        return 0
      end

      codes = lanes.map { |lane| Thread.new { collect(lane) } }.map(&:value)
      return Waiter::DONE_EXIT_TIMEOUT if codes.include?(Waiter::DONE_EXIT_TIMEOUT)

      codes.all?(&:zero?) ? 0 : 1
    end

    # Exposed for `ask --resume` and the MCP server.
    def collect(lane)
      if lane["state"] == "running"
        turn, exit_code = Lanes.wait(lane, @harnex_command, timeout: @options[:timeout])
        exit_code ||= 1
        lane = Lanes.settle(lane, turn, exit_code)
      else
        # Already collected: show the last result again.
        turn = lane["last_turn"] || {}
        exit_code = lane["state"] == "failed" ? 1 : 0
      end
      print_result(lane, turn, exit_code)
      exit_code
    end

    private

    def print_result(lane, turn, exit_code)
      text = if @options[:json]
               JSON.generate(lane: lane["name"], exit_code: exit_code, state: lane["state"], result: turn)
             elsif lane["kind"] == "ask" && exit_code.zero?
               Lanes.final_message(turn)
             else
               Lanes.render(lane, turn, exit_code)
             end
      @print_lock.synchronize do
        @out.puts text
        @out.puts unless @options[:json]
        @out.flush
      end
    end

    def parse
      names = []
      index = 0
      while index < @argv.length
        arg = @argv[index]
        case arg
        when "-h", "--help" then @options[:help] = true
        when "--json" then @options[:json] = true
        when "--timeout"
          value = @argv[index += 1]
          raise OptionParser::MissingArgument, arg if value.nil?

          @options[:timeout] = Lanes.parse_timeout(value)
        when /\A--/
          raise OptionParser::InvalidOption, "harnex result: unknown flag #{arg}; see harnex result --help"
        else
          names << arg
        end
        index += 1
      end
      names
    end
  end
end
