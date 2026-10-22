require "json"
require "open3"
require "securerandom"

module Harnex
  # `harnex mcp` (#87): a stdio MCP server (newline-delimited JSON-RPC 2.0)
  # that exposes the lane verbs as native tools for Claude Code, Pi and any
  # MCP client. Each tool runs the matching CLI verb and returns its text.
  # Blocking calls send progress notifications while the worker runs, which
  # keeps client idle/request timers alive (Claude Code: 30m idle on stdio;
  # Pi: 60s per request, both reset by progress).
  module MCP
    PROTOCOL_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze
    PROGRESS_INTERVAL = 15
    DEFAULT_WAIT_MINUTES = 25

    INSTRUCTIONS = <<~TEXT.freeze
      Harnex hands work to Pi workers (GPT models by default); each runs in a visible tmux window.
      ask: a read-only answer from another model. delegate: a worker does a task; give it a worktree for
      anything that edits, review the diff, then land (land merges and removes the worktree and branch; use it
      instead of merging lane branches by hand). For parallel work call delegate with wait=false for each
      task, then result. reply: a follow-up to the same worker, which keeps its context. Briefs must be
      self-contained: the worker has not seen this conversation. Every result ends with a "── NAME:" footer
      naming the lane's state and next steps.
    TEXT

    MODEL = { "type" => "string", "description" => "Pi model as provider/model (default: Pi's default, e.g. foundry-zyt/gpt-6.1-sol)" }.freeze
    EFFORT = { "type" => "string", "enum" => %w[off minimal low medium high xhigh max], "description" => "Reasoning effort" }.freeze
    WAIT_MINUTES = { "type" => "number", "description" => "How long to wait before returning \"still working\" (default #{DEFAULT_WAIT_MINUTES}); the worker keeps going, collect it later with result" }.freeze
    CWD = { "type" => "string", "description" => "Directory to work in (default: the server's working directory, usually the project root)" }.freeze

    TOOLS = [
      {
        "name" => "ask",
        "title" => "Ask a GPT worker",
        "description" => "Ask a Pi worker (GPT by default) a question and get its answer. Read-only by default: it reads the " \
                         "repository but cannot run commands or change anything. Use for second opinions, explanations " \
                         "and code review; to run tests, scripts or benchmarks, use delegate.",
        "inputSchema" => { "type" => "object", "required" => ["question"], "properties" => {
          "question" => { "type" => "string", "description" => "Self-contained question; the worker has not seen this conversation" },
          "model" => MODEL, "effort" => EFFORT,
          "fallback_model" => { "type" => "string", "description" => "Ask this model instead if the first is rate limited" },
          "write" => { "type" => "boolean", "description" => "Let the worker edit files and run commands (default false)" },
          "cwd" => CWD, "wait_minutes" => WAIT_MINUTES
        } },
        "annotations" => { "readOnlyHint" => false, "openWorldHint" => true }
      },
      {
        "name" => "delegate",
        "title" => "Delegate a task to a GPT worker",
        "description" => "Hand a task to a Pi worker (GPT by default), which edits files, runs commands and replies with " \
                         "a summary. Pass worktree=NAME for anything that edits: the worker gets its own git worktree " \
                         "on branch harnex/NAME and commits there; then review the diff and call land. For parallel " \
                         "work set wait=false for each task and collect them with result. Returns the worker's reply " \
                         "and a footer with commits, cost and next steps.",
        "inputSchema" => { "type" => "object", "required" => ["task"], "properties" => {
          "task" => { "type" => "string", "description" => "Self-contained brief: files, expected behavior, how to verify (e.g. the test command)" },
          "worktree" => { "type" => "string", "description" => "Lane name; work in a new git worktree on branch harnex/NAME (recommended for edits)" },
          "name" => { "type" => "string", "description" => "Lane name when not using a worktree (default: from the task)" },
          "wait" => { "type" => "boolean", "description" => "Wait for the result (default true); false starts the lane and returns at once" },
          "model" => MODEL, "effort" => EFFORT, "cwd" => CWD, "wait_minutes" => WAIT_MINUTES
        } },
        "annotations" => { "readOnlyHint" => false, "destructiveHint" => false, "openWorldHint" => true }
      },
      {
        "name" => "result",
        "title" => "Collect lane results",
        "description" => "Wait for lanes to finish and return each result. With no names: every lane you started in " \
                         "this repo whose result you have not collected (e.g. from delegate with wait=false).",
        "inputSchema" => { "type" => "object", "properties" => {
          "names" => { "type" => "array", "items" => { "type" => "string" }, "description" => "Lane names (default: all your uncollected lanes)" },
          "cwd" => CWD, "wait_minutes" => WAIT_MINUTES
        } },
        "annotations" => { "readOnlyHint" => true, "openWorldHint" => true }
      },
      {
        "name" => "reply",
        "title" => "Follow up with a worker",
        "description" => "Send a lane's worker more work or a correction. The worker keeps its context: a busy worker " \
                         "gets it mid-task, a finished lane resumes its session. Returns the new result.",
        "inputSchema" => { "type" => "object", "required" => %w[name message], "properties" => {
          "name" => { "type" => "string", "description" => "Lane name" },
          "message" => { "type" => "string" },
          "model" => MODEL,
          "wait" => { "type" => "boolean", "description" => "Wait for the result (default true)" },
          "cwd" => CWD, "wait_minutes" => WAIT_MINUTES
        } },
        "annotations" => { "readOnlyHint" => false, "openWorldHint" => true }
      },
      {
        "name" => "land",
        "title" => "Land worktree lanes",
        "description" => "Merge worktree lanes (branch harnex/NAME) into the current branch of the main checkout and " \
                         "remove their worktrees and branches. Without names: every finished worktree lane you " \
                         "started in this repo. On a merge conflict the merge is left in progress: resolve it, git " \
                         "commit, then call land again to clean up.",
        "inputSchema" => { "type" => "object", "properties" => {
          "names" => { "type" => "array", "items" => { "type" => "string" }, "description" => "Lane names, landed in this order (default: all your finished worktree lanes)" },
          "cwd" => CWD
        } },
        "annotations" => { "readOnlyHint" => false, "destructiveHint" => false, "openWorldHint" => false }
      },
      {
        "name" => "discard",
        "title" => "Discard lanes",
        "description" => "Stop lanes and delete their worktrees and branches without merging.",
        "inputSchema" => { "type" => "object", "required" => ["names"], "properties" => {
          "names" => { "type" => "array", "items" => { "type" => "string" } }, "cwd" => CWD
        } },
        "annotations" => { "readOnlyHint" => false, "destructiveHint" => true, "openWorldHint" => false }
      },
      {
        "name" => "lanes",
        "title" => "List lanes",
        "description" => "List this repo's open lanes: state, age, model, branch and the next step for each.",
        "inputSchema" => { "type" => "object", "properties" => {
          "all" => { "type" => "boolean", "description" => "Lanes of every repo" }, "cwd" => CWD
        } },
        "annotations" => { "readOnlyHint" => true, "openWorldHint" => false }
      }
    ].freeze

    class Server
      def initialize(input: $stdin, output: $stdout, harnex_command: nil, progress_interval: PROGRESS_INTERVAL)
        @input = input
        @output = output
        @harnex_command = harnex_command || [Gem.ruby, File.expand_path("../../bin/harnex", __dir__)]
        @progress_interval = progress_interval
        @write_lock = Mutex.new
        @calls = {}
        @calls_lock = Mutex.new
        @threads = []
      end

      def run
        @input.each_line do |line|
          next if line.strip.empty?

          message = begin
            JSON.parse(line)
          rescue JSON::ParserError
            write("jsonrpc" => "2.0", "id" => nil, "error" => { "code" => -32_700, "message" => "parse error" })
            next
          end
          handle(message)
        end
        @threads.each(&:join)
        0
      end

      def handle(message)
        id = message["id"]
        case message["method"]
        when "initialize" then respond(id, initialize_result(message["params"] || {}))
        when "ping" then respond(id, {})
        when "tools/list" then respond(id, "tools" => TOOLS)
        when "tools/call" then @threads << Thread.new { call_tool(id, message["params"] || {}) }
        when "notifications/cancelled" then cancel(message.dig("params", "requestId"))
        when nil, /\Anotifications\// then nil
        else
          write("jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32_601, "message" => "method not found: #{message['method']}" }) unless id.nil?
        end
      end

      private

      def initialize_result(params)
        requested = params["protocolVersion"].to_s
        {
          "protocolVersion" => PROTOCOL_VERSIONS.include?(requested) ? requested : PROTOCOL_VERSIONS[1],
          "capabilities" => { "tools" => { "listChanged" => false } },
          "serverInfo" => { "name" => "harnex", "title" => "Harnex (Pi/GPT workers)", "version" => Harnex::VERSION },
          "instructions" => INSTRUCTIONS
        }
      end

      def call_tool(id, params)
        name = params["name"].to_s
        args = params["arguments"].is_a?(Hash) ? params["arguments"] : {}
        args = name_lanes(name, args)
        argv = argv_for(name, args)
        token = params.dig("_meta", "progressToken")
        text, exit_code = run_cli(id, argv, args["cwd"], token, progress_source(name, args))
        respond(id, "content" => [{ "type" => "text", "text" => text }], "isError" => error_exit?(exit_code))
      rescue ArgumentError => e
        respond(id, "content" => [{ "type" => "text", "text" => e.message }], "isError" => true)
      rescue StandardError => e
        respond(id, "content" => [{ "type" => "text", "text" => "harnex mcp: #{e.class}: #{e.message}" }], "isError" => true)
      end

      # Worker failures are results (the text says FAILED); only a call that
      # could not run (usage error, launch failure) is a tool error.
      def error_exit?(exit_code)
        exit_code == 2 || exit_code.nil?
      end

      def argv_for(name, args)
        wait = ["--timeout", ((args["wait_minutes"] || DEFAULT_WAIT_MINUTES).to_f * 60).round.to_s]
        case name
        when "ask"
          argv = ["ask"] + wait + opt(args, "id") + opt(args, "model") + opt(args, "effort") + opt(args, "fallback_model", "--fallback-model")
          argv << "--write" if args["write"] == true
          argv + ["--", required(args, "question")]
        when "delegate"
          argv = ["delegate"] + wait + opt(args, "worktree") + opt(args, "name") + opt(args, "model") + opt(args, "effort")
          argv << "--no-wait" if args["wait"] == false
          argv + ["--", required(args, "task")]
        when "result"
          ["result"] + wait + Array(args["names"] || args["name"]).map(&:to_s)
        when "reply"
          argv = ["reply"] + wait + opt(args, "model")
          argv << "--no-wait" if args["wait"] == false
          argv + [required(args, "name"), "--", required(args, "message")]
        when "land", "discard"
          names = Array(args["names"] || args["name"] || args["lanes"]).map(&:to_s).reject(&:empty?)
          raise ArgumentError, "discard: names is required" if names.empty? && name == "discard"

          [name] + names
        when "lanes"
          ["lanes"] + (args["all"] == true ? ["--all"] : [])
        else
          raise ArgumentError, "unknown tool #{name.inspect}"
        end
      end

      def opt(args, key, flag = "--#{key}")
        value = args[key]
        value.nil? || value.to_s.strip.empty? ? [] : [flag, value.to_s]
      end

      # Agents reach for the argument names of their other tools (the Agent
      # tool's `prompt`); accept the common synonyms instead of failing.
      ALIASES = {
        "task" => %w[prompt brief message instructions],
        "question" => %w[prompt query message],
        "message" => %w[prompt text task],
        "name" => %w[lane id worktree]
      }.freeze

      def required(args, key)
        value = ([key] + ALIASES.fetch(key, [])).map { |k| args[k] }.find { |v| !v.to_s.strip.empty? }.to_s
        raise ArgumentError, "#{key} is required" if value.strip.empty?

        value
      end

      # Name lanes up front so progress can follow them while the call runs.
      def name_lanes(tool, args)
        args = args.dup
        case tool
        when "delegate"
          if args["worktree"].to_s.empty? && args["name"].to_s.empty?
            root = Lanes.main_root(work_dir(args)) || work_dir(args)
            args["name"] = Lanes.generate_name(root, args["task"] || args["prompt"] || args["brief"])
          end
        when "ask"
          args["id"] ||= "pi-ask-#{SecureRandom.hex(2)}"
        end
        args
      end

      def work_dir(args)
        args["cwd"].to_s.strip.empty? ? Dir.pwd : File.expand_path(args["cwd"])
      end

      # Returns a lambda giving the current progress message.
      def progress_source(tool, args)
        names = case tool
                when "delegate" then [args["worktree"] || args["name"]]
                when "ask" then [args["id"]]
                when "reply" then [args["name"]]
                when "result" then Array(args["names"])
                else []
                end.compact.map(&:to_s).reject(&:empty?)
        dir = work_dir(args)
        lambda do |elapsed|
          lanes = names.empty? && tool == "result" ? Lanes.pending(from: dir) : names.filter_map { |n| lane_or_nil(n, dir) }
          lines = lanes.map { |lane| Lanes.progress_line(lane) }
          lines.empty? ? "harnex #{tool}: working (#{elapsed / 60}m#{format('%02d', elapsed % 60)}s)" : lines.join("; ")
        end
      end

      def lane_or_nil(name, dir)
        Lanes.resolve(name, from: dir)
      rescue OptionParser::InvalidArgument
        nil
      end

      # Runs the CLI verb in its own process group (so a cancel stops only the
      # wait; the worker keeps running in tmux) and reports progress while it
      # runs.
      def run_cli(id, argv, cwd, token, label)
        dir = cwd.to_s.strip.empty? ? Dir.pwd : File.expand_path(cwd)
        raise ArgumentError, "cwd #{dir} is not a directory" unless File.directory?(dir)

        Open3.popen3(*(@harnex_command + argv), chdir: dir, pgroup: true) do |stdin, stdout, stderr, wait|
          stdin.close
          track(id, wait.pid)
          out = Thread.new { stdout.read }
          err = Thread.new { stderr.read }
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          ticks = 0
          until wait.join(@progress_interval)
            ticks += 1
            elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round
            progress(token, ticks, progress_text(label, elapsed)) if token
          end
          cancelled = cancelled?(id)
          untrack(id)
          status = wait.value
          text = out.value.to_s.rstrip
          errors = err.value.to_s.strip
          text = [text, errors].reject(&:empty?).join("\n") if !status.success? || text.empty?
          return [cancelled ? "cancelled; the worker keeps running (see the lanes tool)" : text, status.exitstatus]
        end
      end

      def progress_text(source, elapsed)
        source.call(elapsed)
      rescue StandardError
        "harnex: working (#{elapsed}s)"
      end

      def progress(token, value, message)
        write("jsonrpc" => "2.0", "method" => "notifications/progress",
              "params" => { "progressToken" => token, "progress" => value, "message" => message })
      end

      def track(id, pid)
        @calls_lock.synchronize { @calls[id] = { pid: pid, cancelled: false } }
      end

      def untrack(id)
        @calls_lock.synchronize { @calls.delete(id) }
      end

      def cancelled?(id)
        @calls_lock.synchronize { @calls.dig(id, :cancelled) } == true
      end

      def cancel(request_id)
        call = @calls_lock.synchronize { @calls[request_id]&.tap { |c| c[:cancelled] = true } }
        Process.kill("-TERM", call[:pid]) if call
      rescue Errno::ESRCH
        nil
      end

      def respond(id, result)
        return if id.nil?

        write("jsonrpc" => "2.0", "id" => id, "result" => result)
      end

      def write(message)
        @write_lock.synchronize do
          @output.write(JSON.generate(message) + "\n")
          @output.flush
        end
      end
    end
  end
end
