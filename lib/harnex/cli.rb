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
      when "watch"
        WatchCommand.new(@argv.drop(1)).run
      when "stop"
        Stopper.new(@argv.drop(1)).run
      when "status"
        Status.new(@argv.drop(1)).run
      when "logs"
        Logs.new(@argv.drop(1)).run
      when "events"
        Events.new(@argv.drop(1)).run
      when "history"
        History.new(@argv.drop(1)).run
      when "pane"
        Pane.new(@argv.drop(1)).run
      when "recipes"
        Recipes.new(@argv.drop(1)).run
      when "guide"
        Guide.new.run
      when "agents-guide"
        AgentsGuide.new(@argv.drop(1)).run
      when "doctor"
        Doctor.new(@argv.drop(1)).run
      when "preflight"
        Preflight.new(@argv.drop(1)).run
      when "ask"
        Ask.new(@argv.drop(1)).run
      when "delegate"
        Delegate.new(@argv.drop(1)).run
      when "result"
        LaneResult.new(@argv.drop(1)).run
      when "reply"
        Reply.new(@argv.drop(1)).run
      when "land"
        Land.new(@argv.drop(1)).run
      when "discard"
        Land.new(@argv.drop(1), discard: true).run
      when "lanes"
        LanesCommand.new(@argv.drop(1)).run
      when "orchestration"
        OrchestrationCommand.new(@argv.drop(1)).run
      when "artifact-report"
        ArtifactReportCommand.new(@argv.drop(1)).run
      when "telemetry"
        TelemetryCommand.new(@argv.drop(1)).run
      when "help"
        puts help(@argv[1])
        0
      when "-v", "--version", "version"
        puts "harnex #{Harnex::VERSION} (#{Harnex::RELEASE_DATE})"
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
      when "watch"
        WatchCommand.usage
      when "stop"
        Stopper.usage
      when "status"
        Status.usage
      when "logs"
        Logs.usage
      when "events"
        Events.usage
      when "history"
        History.usage
      when "pane"
        Pane.usage
      when "recipes"
        Recipes.usage
      when "guide"
        Guide.usage
      when "agents-guide"
        AgentsGuide.usage
      when "doctor"
        Doctor.usage
      when "preflight"
        Preflight.usage
      when "ask"
        Ask.usage
      when "delegate"
        Delegate.usage
      when "result"
        LaneResult.usage
      when "reply"
        Reply.usage
      when "land"
        Land.usage
      when "discard"
        Land.usage(discard: true)
      when "lanes"
        LanesCommand.usage
      when "orchestration"
        OrchestrationCommand.usage
      when "artifact-report"
        ArtifactReportCommand.usage
      when "telemetry"
        TelemetryCommand.usage
      else
        usage
      end
    end

    def usage
      <<~TEXT
        harnex: Pi workers (GPT models) as tools for you and your agents.

        Hand work to a worker (each runs in a visible tmux window):
          harnex ask QUESTION                 A read-only answer from another model
          harnex delegate [--worktree NAME] TASK
                                              A worker does the task; prints its reply
          harnex delegate --no-wait ...       Start lanes in parallel, then:
          harnex result [NAME...]             Wait for lanes and print their results
          harnex reply NAME MESSAGE           Follow up; the worker keeps its context
          harnex land NAME                    Merge a worktree lane, remove the worktree
          harnex discard NAME                 Drop a lane and its worktree
          harnex lanes                        Your lanes and what each needs next

          Blocking commands wait 9m by default and exit 124 if the worker is still
          going; run `harnex result NAME` to keep waiting. Exit 0 done, 1 failed.

        Low-level session control:
          harnex run <cli> [options] [--] [cli-args...]
          harnex send --id ID [options] [text...]
          harnex wait --id ID [options]
          harnex watch --id ID [options]
          harnex stop --id ID [options]
          harnex status [options]
          harnex logs --id ID [options]
          harnex events --id ID [options]
          harnex history [options]
          harnex pane --id ID [options]

        Setup, docs and telemetry:
          harnex doctor                       Check Pi and harnex setup
          harnex preflight ADAPTER [options]  Prove an adapter with one tiny dispatch
          harnex agents-guide [topic]         Agent guides (dispatch, chain, buddy, monitoring, naming, claude)
          harnex guide | recipes              Getting started; workflow recipes
          harnex orchestration sample|report [options]
          harnex artifact-report init|validate PATH [options]
          harnex telemetry assert-canonical|reconcile [options]
          harnex help [command]

        Examples:
          harnex ask "Where is the dispatch row written, and is that path tested?"
          harnex delegate --worktree word-count "Add TextKit.word_count with a test"
          harnex land word-count
          harnex delegate --no-wait --worktree fix-a "Fix A"; harnex delegate --no-wait --worktree fix-b "Fix B"; harnex result
          harnex run pi --tmux pi-i-42 --id pi-i-42 --context-file /tmp/task-42.md
      TEXT
    end
  end
end
