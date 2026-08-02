require "json"
require "net/http"
require "optparse"
require "uri"

module Harnex
  class Waiter
    POLL_INTERVAL = 0.5
    EVENT_POLL_INTERVAL = 0.1
    EXIT_STATUS_GRACE_SECONDS_DEFAULT = 5.0
    EXIT_STATUS_GRACE_POLL_INTERVAL = 0.05
    FINAL_EVENT_GRACE_SECONDS = 5.0

    EVENT_PREDICATES = %w[task_complete task_failed].freeze
    LEGACY_EVENT_TYPES = %w[agent_state exited task_complete task_failed].freeze

    # Exit-code contract for `--until done` (documented in guides/04_monitoring.md).
    DONE_EXIT_DONE = 0
    DONE_EXIT_FAILED = 1
    DONE_EXIT_REJECTED_PROOF = 2
    DONE_EXIT_NO_SESSION = 3
    DONE_EXIT_TIMEOUT = 124

    # Outcome classes where the process completed but the work was not
    # accepted: proof was missing, invalid, rejected, or nothing happened.
    REJECTED_PROOF_CLASSES = %w[
      completed_no_activity report_missing report_invalid report_rejected
    ].freeze

    def self.usage(program_name = "harnex wait")
      <<~TEXT
        Usage: #{program_name} [options]

        Options:
          --id ID         Session ID to wait for (required)
          --until STATE   Wait until session reaches STATE. Supported:
                            done            (work fence — task_complete,
                                             task_failed, or terminal exit,
                                             whichever comes first)
                            task_complete   (events JSONL — fires on
                                             successful turn completion)
                            task_failed     (events JSONL — fires on
                                             failed turn completion)
                            <other>         (agent_state HTTP poll, e.g.
                                             "prompt", "busy")
                          Without --until, waits for session exit (default).
          --repo PATH     Resolve session using PATH's repo root (default: current repo)
          --timeout SECS  Maximum time to wait in seconds (default: unlimited)
          -h, --help      Show this help

        Common patterns:
          #{program_name} --id cx-i-42 --until done --timeout 900
          #{program_name} --id cx-i-42 --until task_complete --timeout 900
          #{program_name} --id cx-i-42 --until prompt --timeout 120
          #{program_name} --id cx-i-42

        Exit codes for --until done:
          0    completed with accepted work
          1    failed (work failed, process failed, or killed)
          2    completed but proof rejected (completed_no_activity,
               report_missing, report_invalid, report_rejected)
          3    no such session (no live, start, event, or terminal signal)
          124  --timeout elapsed while the session was still running

        Gotchas:
          done is the safest work-level fence for monitors.
          While the session's pid is alive, --until done blocks (up to
          --timeout); "no signal yet" from a live worker is never terminal.
          task_complete/task_failed are event predicates; prompt/busy are live state polls.
          Prompt state alone does not prove work acceptance. Verify artifacts/tests.
          Exit waits can resolve from terminal summary rows when live registry/
          exit-status files are already gone.
          Without --timeout, wait can block indefinitely.
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {
        id: nil,
        until_state: nil,
        repo_path: Dir.pwd,
        timeout: nil,
        help: false
      }
    end

    def run
      parser.parse!(@argv)
      if @options[:help]
        puts self.class.usage
        return 0
      end

      raise "--id is required for harnex wait" unless @options[:id]

      if @options[:until_state]
        case @options[:until_state]
        when "done"
          wait_until_done
        when *EVENT_PREDICATES
          wait_until_event(@options[:until_state])
        else
          wait_until_state
        end
      else
        wait_until_exit
      end
    end

    private

    def wait_until_event(predicate)
      repo_root = Harnex.resolve_repo_root(@options[:repo_path])
      events_path = Harnex.events_log_path(repo_root, @options[:id])
      registry = Harnex.read_registry(repo_root, @options[:id])
      start_time = Time.now
      deadline = @options[:timeout] ? start_time + @options[:timeout] : nil

      unless registry || File.exist?(events_path)
        warn("harnex wait: no session found with id #{@options[:id].inspect}")
        return 1
      end

      offset = 0
      task_complete_seen = false
      final_event_deadline = nil

      # Replay existing events first — we may already be past the predicate.
      status, offset, task_complete_seen = scan_events(events_path, offset, predicate, task_complete_seen, start_time)
      return status if status

      target_pid = registry && registry["pid"]

      loop do
        status, offset, task_complete_seen = scan_events(events_path, offset, predicate, task_complete_seen, start_time)
        return status if status

        if deadline && Time.now >= deadline
          waited = (Time.now - start_time).round(1)
          puts JSON.generate(ok: false, id: @options[:id], status: "timeout", waited_seconds: waited)
          return 124
        end

        if target_pid && !Harnex.alive_pid?(target_pid)
          final_event_deadline ||= Time.now + FINAL_EVENT_GRACE_SECONDS
          if Time.now >= final_event_deadline
            waited = (Time.now - start_time).round(1)
            puts JSON.generate(ok: false, id: @options[:id], state: "exited", waited_seconds: waited)
            return 1
          end
        else
          final_event_deadline = nil
        end

        sleep EVENT_POLL_INTERVAL
      end
    end

    # min_ts: with a live session in view, events written before it started
    # belong to an earlier run that reused the id — never match on them.
    def scan_events(path, offset, predicate, task_complete_seen, start_time, min_ts: nil)
      return [nil, offset, task_complete_seen] unless File.exist?(path) && File.size(path) > offset

      File.open(path, "r") do |f|
        f.seek(offset)
        f.each_line do |line|
          event = parse_event(line)
          next unless event
          next if stale_event?(event, min_ts)

          task_complete_seen = true if %w[task_complete task_failed].include?(event_type(event))
          if matches?(event, predicate, task_complete_seen)
            return [emit_event_match(event, start_time, predicate), f.pos, task_complete_seen]
          end
        end
        offset = f.pos
      end

      [nil, offset, task_complete_seen]
    end

    def stale_event?(event, min_ts)
      return false unless min_ts

      # Events without a parseable ts (legacy formats) cannot be dated;
      # treat them as fresh rather than silently dropping completion signals.
      ts = parse_wait_time(event["ts"])
      return false unless ts

      ts < min_ts
    end

    def parse_event(line)
      event = JSON.parse(line)
      event.is_a?(Hash) ? event : nil
    rescue JSON::ParserError
      legacy_type = line.to_s.strip
      return nil unless LEGACY_EVENT_TYPES.include?(legacy_type)

      { "type" => legacy_type }
    end

    def event_type(event)
      type = event["type"]
      return type if type.is_a?(String) && !type.empty?

      legacy_type = event["terminal_event"] || event["event"]
      legacy_type = legacy_type.to_s
      LEGACY_EVENT_TYPES.include?(legacy_type) ? legacy_type : nil
    end

    def matches?(event, predicate, task_complete_seen)
      type = event_type(event)
      case predicate
      when "task_complete"
        type == "task_complete"
      when "task_failed"
        type == "task_failed"
      when "done"
        %w[task_complete task_failed].include?(type)
      when "prompt"
        type == "task_complete" ||
          (task_complete_seen && type == "agent_state" && event["state"] == "prompt")
      else
        false
      end
    end

    def done_event_failed?(event)
      return true if event_type(event) == "task_failed"

      status = event["status"].to_s
      !status.empty? && !%w[completed success succeeded].include?(status)
    end

    def emit_event_match(event, start_time, predicate)
      waited = (Time.now - start_time).round(1)
      payload = {
        ok: true,
        id: @options[:id],
        event: event_type(event),
        seq: event["seq"],
        waited_seconds: waited
      }
      exit_code = 0
      if predicate == "done"
        failed = done_event_failed?(event)
        exit_code = failed ? done_failure_exit_code(event["outcome_class"]) : DONE_EXIT_DONE
        payload.merge!(
          ok: !failed,
          status: failed ? "failed" : "done",
          wait_result: done_wait_result(exit_code),
          state: "running",
          process_state: "running",
          terminal: false,
          task_complete: !failed,
          task_failed: failed,
          done: !failed,
          work_state: failed ? "failed" : "completed",
          outcome_class: event["outcome_class"],
          artifact_report_status: event["artifact_report_status"]
        )
        payload[:last_error] = event["message"] || event["error"] if failed
      end
      puts JSON.generate(payload)
      exit_code
    end

    def done_failure_exit_code(outcome_class)
      REJECTED_PROOF_CLASSES.include?(outcome_class.to_s) ? DONE_EXIT_REJECTED_PROOF : DONE_EXIT_FAILED
    end

    def done_wait_result(exit_code)
      case exit_code
      when DONE_EXIT_DONE then "done"
      when DONE_EXIT_REJECTED_PROOF then "rejected_proof"
      else "failed"
      end
    end

    # Contract: while the session's pid is alive, block (up to --timeout).
    # Liveness is re-checked every poll from the registry, falling back to an
    # uncompleted dispatch-start row, so a running worker is never classified
    # as dead just because one signal source is missing. "No signal yet"
    # while alive is not terminal.
    def wait_until_done
      repo_root = Harnex.resolve_repo_root(@options[:repo_path])
      events_path = Harnex.events_log_path(repo_root, @options[:id])
      exit_path = Harnex.exit_status_path(repo_root, @options[:id])
      start_time = Time.now
      deadline = @options[:timeout] ? start_time + @options[:timeout] : nil

      offset = 0
      task_complete_seen = false
      observed_live = nil
      session_started_at = nil

      loop do
        live = live_session(repo_root)
        if live
          observed_live = live
          session_started_at ||= parse_wait_time(live["started_at"])
        end

        status, offset, task_complete_seen =
          scan_events(events_path, offset, "done", task_complete_seen, start_time, min_ts: session_started_at)
        return status if status

        unless live
          if observed_live
            return resolve_after_exit(repo_root, events_path, exit_path, offset,
                                      task_complete_seen, start_time, observed_live, session_started_at)
          end

          # Historical query: never observed the session alive.
          return emit_done_exit_status(exit_path, @options[:id]) if File.exist?(exit_path)

          terminal = done_status(repo_root)
          return emit_done_terminal_status(terminal) if terminal

          unless File.exist?(events_path)
            warn("harnex wait: no session found with id #{@options[:id].inspect}")
            puts JSON.generate(ok: false, id: @options[:id], status: "no_such_session",
                               wait_result: "no_such_session", state: "unknown", process_state: "unknown",
                               terminal: false, task_complete: false, done: false, work_state: "unknown")
            return DONE_EXIT_NO_SESSION
          end
        end

        if deadline && Time.now >= deadline
          waited = (Time.now - start_time).round(1)
          puts JSON.generate(ok: false, id: @options[:id], status: "timeout", wait_result: "timeout",
                             waited_seconds: waited, done: false,
                             work_state: live ? "running" : "unknown")
          return DONE_EXIT_TIMEOUT
        end

        sleep EVENT_POLL_INTERVAL
      end
    end

    # Registry row first; when it is not visible from this context, an
    # uncompleted dispatch-start row with an alive pid still proves liveness.
    def live_session(repo_root)
      registry = Harnex.read_registry(repo_root, @options[:id])
      return registry if registry

      Harnex::DispatchHistory.live_start_record(repo_root: repo_root, id: @options[:id])
    end

    # The session was alive and its pid is now gone: give teardown a bounded
    # grace to land the final events, summary row, and exit-status file, then
    # classify from the freshest signal that belongs to the observed session.
    def resolve_after_exit(repo_root, events_path, exit_path, offset, task_complete_seen,
                           start_time, observed_live, session_started_at)
      await_exit_status(exit_path)

      status, _offset, _seen =
        scan_events(events_path, offset, "done", task_complete_seen, start_time, min_ts: session_started_at)
      return status if status

      if File.exist?(exit_path) && fresh_exit_status?(exit_path, observed_live, session_started_at)
        return emit_done_exit_status(exit_path, @options[:id])
      end

      terminal = done_status(repo_root, min_started_at: session_started_at)
      return emit_done_terminal_status(terminal) if terminal

      waited = (Time.now - start_time).round(1)
      puts JSON.generate(ok: false, id: @options[:id], state: "exited", process_state: "exited",
                         terminal: true, task_complete: false, done: false, work_state: "unknown",
                         wait_result: "failed", waited_seconds: waited)
      DONE_EXIT_FAILED
    end

    # Guards against classifying from an exit-status file left behind by an
    # earlier dispatch that reused the same id.
    def fresh_exit_status?(exit_path, observed_live, session_started_at)
      data = JSON.parse(File.read(exit_path))
      observed_session_id = observed_live["session_id"].to_s
      exit_session_id = data["session_id"].to_s
      return exit_session_id == observed_session_id unless exit_session_id.empty? || observed_session_id.empty?

      exited_at = parse_wait_time(data["exited_at"])
      return true unless exited_at && session_started_at

      exited_at >= session_started_at
    rescue StandardError
      true
    end

    def parse_wait_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def wait_until_state
      repo_root = Harnex.resolve_repo_root(@options[:repo_path])
      target_state = @options[:until_state]
      start_time = Time.now
      deadline = @options[:timeout] ? start_time + @options[:timeout] : nil

      registry = Harnex.read_registry(repo_root, @options[:id])
      unless registry
        warn("harnex wait: no session found with id #{@options[:id].inspect}")
        return 1
      end

      target_pid = registry["pid"]
      host = registry["host"]
      port = registry["port"]
      token = registry["token"]

      warn("harnex wait: waiting for #{@options[:id]} to reach #{target_state}")

      loop do
        unless Harnex.alive_pid?(target_pid)
          waited = (Time.now - start_time).round(1)
          puts JSON.generate(ok: false, id: @options[:id], state: "exited", waited_seconds: waited)
          return 1
        end

        state = fetch_agent_state(host, port, token)
        if state == target_state
          waited = (Time.now - start_time).round(1)
          puts JSON.generate(ok: true, id: @options[:id], state: state, waited_seconds: waited)
          return 0
        end

        if deadline && Time.now >= deadline
          waited = (Time.now - start_time).round(1)
          puts JSON.generate(ok: false, id: @options[:id], state: state || "unknown", waited_seconds: waited, status: "timeout")
          return 124
        end

        sleep POLL_INTERVAL
      end
    end

    def wait_until_exit
      repo_root = Harnex.resolve_repo_root(@options[:repo_path])
      deadline = @options[:timeout] ? Time.now + @options[:timeout] : nil
      exit_path = Harnex.exit_status_path(repo_root, @options[:id])

      registry = Harnex.read_registry(repo_root, @options[:id])
      unless registry
        return read_exit_status(exit_path, @options[:id]) if File.exist?(exit_path)

        terminal = terminal_status(repo_root)
        return emit_terminal_status(terminal) if terminal

        warn("harnex wait: no session found with id #{@options[:id].inspect}")
        puts JSON.generate(ok: false, id: @options[:id], state: "unknown", process_state: "unknown",
                           terminal: false, task_complete: false, done: false, work_state: "unknown", status: "unknown")
        return 1
      end

      target_pid = registry["pid"]
      warn("harnex wait: watching session #{@options[:id]} (pid #{target_pid})")

      loop do
        unless Harnex.alive_pid?(target_pid)
          await_exit_status(exit_path)
          return read_exit_status(exit_path, @options[:id]) if File.exist?(exit_path)

          terminal = terminal_status(repo_root)
          return emit_terminal_status(terminal) if terminal

          puts JSON.generate(ok: false, id: @options[:id], state: "unknown", process_state: "unknown",
                             terminal: false, task_complete: false, done: false, work_state: "unknown", status: "unknown")
          return 1
        end

        if deadline && Time.now >= deadline
          puts JSON.generate(ok: false, id: @options[:id], status: "timeout", pid: target_pid)
          return 124
        end

        sleep POLL_INTERVAL
      end
    end

    # Subprocess death races the parent's DISPATCH-row write; the exit-status
    # file is written *after* the row, so polling it bounds the race.
    def await_exit_status(exit_path)
      return if File.exist?(exit_path)

      grace_deadline = Time.now + exit_status_grace_seconds
      until File.exist?(exit_path) || Time.now >= grace_deadline
        sleep EXIT_STATUS_GRACE_POLL_INTERVAL
      end
    end

    def exit_status_grace_seconds
      override = ENV["HARNEX_EXIT_STATUS_GRACE_SECONDS"]
      return EXIT_STATUS_GRACE_SECONDS_DEFAULT if override.to_s.strip.empty?

      Float(override)
    rescue ArgumentError
      EXIT_STATUS_GRACE_SECONDS_DEFAULT
    end

    def fetch_agent_state(host, port, token)
      uri = URI("http://#{host}:#{port}/status")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{token}" if token

      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 1) do |http|
        http.request(request)
      end

      return nil unless response.is_a?(Net::HTTPSuccess)

      data = JSON.parse(response.body)
      data["agent_state"]
    rescue StandardError
      nil
    end

    def read_exit_status(exit_path, id)
      if File.exist?(exit_path)
        data = JSON.parse(File.read(exit_path))
        puts JSON.generate(data)
        data["exit_code"] || 0
      else
        puts JSON.generate(ok: true, id: id, status: "exited")
        0
      end
    end

    def terminal_status(repo_root)
      status = Harnex::TerminalStatus.resolve(id: @options[:id], repo_root: repo_root)
      return nil unless status
      return nil unless status["terminal"]

      status
    end

    def done_status(repo_root, min_started_at: nil)
      status = Harnex::TerminalStatus.resolve(id: @options[:id], repo_root: repo_root)
      return nil unless status
      return nil unless status["done"] || status["terminal"]

      if min_started_at
        row_started = parse_wait_time(status["started_at"])
        return nil if row_started && row_started < min_started_at
      end

      status
    end

    def emit_done_exit_status(exit_path, id)
      data = JSON.parse(File.read(exit_path))
      exit_code = data["exit_code"]
      task_complete = data["task_complete"] == true || data["task_complete"].to_s == "true"
      task_failed = data["task_failed"] == true || data["task_failed"].to_s == "true"
      exit_success = !task_failed && (exit_code.nil? || exit_code.to_i == 0)
      state = exit_success ? "completed" : "failed"
      done = task_complete || exit_success
      result_code = done ? DONE_EXIT_DONE : done_failure_exit_code(data["outcome_class"])
      payload = data.merge(
        "ok" => done,
        "id" => id,
        "state" => state,
        "process_state" => "exited",
        "terminal" => true,
        "task_complete" => task_complete,
        "task_failed" => task_failed,
        "done" => done,
        "work_state" => Harnex.work_state_for(state, task_complete: task_complete),
        "wait_result" => done_wait_result(result_code)
      )
      puts JSON.generate(payload)
      result_code
    rescue JSON::ParserError
      puts JSON.generate(ok: false, id: id, state: "failed", process_state: "exited", terminal: true,
                         task_complete: false, done: false, work_state: "failed",
                         status: "invalid_exit_status", wait_result: "failed")
      DONE_EXIT_FAILED
    end

    def emit_done_terminal_status(status)
      payload = terminal_payload(status)
      payload[:ok] = !!payload[:done]
      payload[:status] = payload[:done] ? "done" : status["state"]
      result_code = payload[:done] ? DONE_EXIT_DONE : done_failure_exit_code(status["outcome_class"])
      payload[:wait_result] = done_wait_result(result_code)
      puts JSON.generate(payload)
      result_code
    end

    def emit_terminal_status(status)
      payload = terminal_payload(status)
      payload[:ok] = status["state"] == "completed"
      puts JSON.generate(payload)

      if payload[:ok]
        0
      elsif status["exit_code"].is_a?(Integer) && status["exit_code"] > 0
        status["exit_code"]
      else
        1
      end
    end

    def terminal_payload(status)
      task_complete = !!status["task_complete"]
      task_failed = !!status["task_failed"]
      work_state = status["work_state"] || Harnex.work_state_for(status["state"], task_complete: task_complete)
      done = status.key?("done") ? !!status["done"] : work_state == "completed"
      {
        ok: false,
        id: status["id"],
        state: status["state"],
        process_state: status["process_state"] || Harnex.process_state_for(status["state"], terminal: true),
        terminal: status.key?("terminal") ? !!status["terminal"] : true,
        task_complete: task_complete,
        task_failed: task_failed,
        done: done,
        work_state: work_state,
        outcome_class: status["outcome_class"],
        artifact_report_status: status["artifact_report_status"],
        exit: status["exit"],
        exit_code: status["exit_code"],
        summary_out: status["summary_out"],
        ended_at: status["ended_at"],
        source: status["source"]
      }
    end

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: harnex wait [options]"
        opts.on("--id ID", "Session ID to wait for") { |value| @options[:id] = Harnex.normalize_id(value) }
        opts.on("--until STATE", "Wait until session reaches STATE") { |value| @options[:until_state] = value }
        opts.on("--repo PATH", "Resolve session using PATH's repo root") { |value| @options[:repo_path] = value }
        opts.on("--timeout SECONDS", Float, "Maximum time to wait") { |value| @options[:timeout] = value }
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end
  end
end
