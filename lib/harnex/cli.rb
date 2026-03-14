module Harnex
  class CLI
    def initialize(argv)
      @argv = argv.dup
    end

    def run
      case @argv.first
      when nil
        Runner.new([]).run
      when "run"
        Runner.new(@argv.drop(1)).run
      when "send"
        Sender.new(@argv.drop(1)).run
      when "wait"
        Waiter.new(@argv.drop(1)).run
      when "exit"
        Exiter.new(@argv.drop(1)).run
      when "status"
        Status.new(@argv.drop(1)).run
      when "help"
        puts help(@argv[1])
        0
      when "-h", "--help"
        puts usage
        0
      else
        Runner.new(@argv).run
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
      when "exit"
        Exiter.usage
      when "status"
        Status.usage
      else
        usage
      end
    end

    def usage
      <<~TEXT
        Usage:
          harnex run [cli] [wrapper-options] [--] [cli-args...]
          harnex send [options] [text...]
          harnex wait --id ID [options]
          harnex exit --id ID [options]
          harnex status [options]
          harnex [cli] [wrapper-options] [--] [cli-args...]

        Commands:
          run    Start a wrapped interactive session and local API
          send   Send text or inspect status for an active session
          wait   Block until a detached session exits
          exit   Send exit sequence to a session
          status List live sessions for this repo

        Notes:
          The bare `harnex` form is an alias for `harnex run #{DEFAULT_CLI}`.
          Supported CLIs: #{Adapters.supported.join(', ')}

        Examples:
          harnex
          harnex run codex
          harnex run codex --id hello
          harnex run codex -- --cd /path/to/repo
          harnex status
          harnex send --id main --message "Summarize current progress."
      TEXT
    end
  end
end
