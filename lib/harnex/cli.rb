module Harnex
  class CLI
    def initialize(argv)
      @argv = argv.dup
    end

    def run
      case @argv.first
      when nil
        puts usage
        0
      when "run"
        Runner.new(@argv.drop(1)).run
      when "send"
        Sender.new(@argv.drop(1)).run
      when "wait"
        Waiter.new(@argv.drop(1)).run
      when "stop"
        Stopper.new(@argv.drop(1)).run
      when "status"
        Status.new(@argv.drop(1)).run
      when "help"
        puts help(@argv[1])
        0
      when "-h", "--help"
        puts usage
        0
      else
        raise OptionParser::ParseError, "unknown command #{@argv.first.inspect}"
      end
    end

    private

    def help(topic)
      case topic
      when "run"
        Runner.usage
      when "send"
        Sender.usage
      when "wait"
        Waiter.usage
      when "stop"
        Stopper.usage
      when "status"
        Status.usage
      else
        usage
      end
    end

    def usage
      <<~TEXT
        Usage:
          harnex run <cli> [options] [--] [cli-args...]
          harnex send --id ID [options] [text...]
          harnex wait --id ID [options]
          harnex stop --id ID [options]
          harnex status [options]
          harnex help [command]

        Commands:
          run     Start a wrapped interactive session and local API
          send    Send text to an active session
          wait    Block until a session exits or reaches a state
          stop    Send the adapter stop sequence to a session
          status  List live sessions
          help    Show command help

        Notes:
          CLIs with smart prompt detection: #{Adapters.known.join(', ')}
          Any other CLI name is launched with generic wrapping.

        Examples:
          harnex run codex
          harnex run aider --id blue-cat
          harnex run codex -- --cd /path/to/repo
          harnex status
          harnex send --id main --message "Summarize current progress."
      TEXT
    end
  end
end
