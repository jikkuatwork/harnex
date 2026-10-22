require "json"
require "net/http"
require "optparse"
require "stringio"
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
    DONE_EXIT_STALLED = 4
    DONE_EXIT_TIMEOUT = 124
    # Stall checks poll the live status API; detection lags by at most this.
    STALL_POLL_MAX_INTERVAL = 15.0

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
          --timeout DUR   Hard observer cap (seconds, or suffix s/m/h; default: unlimited)
          --max-wait DUR  Alias for --timeout
          --heartbeat DUR  Flush observed progress to stderr at this interval (default: off)
          --after-seq N   With --until done/task_complete/task_failed: ignore every
                          event at or before events-log seq N (the after_seq that
                          `harnex send` reports), so the wait covers the turn that
                          message started or joined, not an earlier result.
          --since TIME    With --until done: ignore events before TIME (ISO 8601),
                          e.g. an earlier launch of a lane relaunched under the
                          same id (each launch restarts the events-log seq)
          --stall-after DUR
                          With --until done: exit 4 when the live session shows no
                          progress for DUR (Pi/structured: model, tool or turn
                          events during an active turn; PTY: transcript idle).
                          Never nudges or stops the worker.
          -h, --help      Show this help

        Common patterns:
          #{program_name} --id pi-i-42 --until done --timeout 900
          #{program_name} --id pi-i-42 --until done --stall-after 25m --timeout 4h
          #{program_name} --id pi-i-42 --until done --after-seq 812 --timeout 9m
          #{program_name} --id pi-i-42 --until task_complete --timeout 900
          #{program_name} --id pi-i-42 --until prompt --timeout 120
          #{program_name} --id pi-i-42

        Exit codes for --until done:
          0    completed with accepted work
          1    failed (work failed, process failed, or killed)
          2    completed but proof rejected (completed_no_activity,
               report_missing, report_invalid, report_rejected)
          3    no such session (no live, start, event, or terminal signal)
          4    stalled: no progress for --stall-after (worker left running)
          124  observer deadline elapsed (does not stop the worker)

        Gotchas:
          done is the safest work-level fence for monitors.
          A bare wait returns only on process exit; sessions without
          --auto-stop stay alive after their turn (stderr notes say so).
          While the session's pid is alive, --until done blocks (up to
          --timeout); "no signal yet" from a live worker is never terminal.
          task_complete/task_failed are event predicates; prompt/busy are live state polls.
          Prompt state alone does not prove work acceptance. Verify artifacts/tests.
          Exit waits can resolve from terminal summary rows when live registry/
          exit-status files are already gone.
          Without --timeout, wait can block indefinitely.
      TEXT
    end

    # Reuse the shared duration grammar while preserving wait's numeric
    # timeout syntax and guarding numeric fallback/forwarded Float values.
    def self.duration(value, option_name:)
      seconds = begin
        Harnex.parse_duration_seconds(value, option_name: option_name)
      rescue OptionParser::InvalidArgument => invalid_duration
        # Preserve wait --timeout's former Float syntax (e.g. .5 or 1e-3),
        # also used by Float#to_s when watch forwards very small intervals.
        begin
          Float(value)
        rescue ArgumentError, TypeError
          raise invalid_duration
        end
      end
      unless seconds.finite? && seconds.positive?
        raise OptionParser::InvalidArgument, "#{option_name} must be a finite positive duration"
      end
      seconds
    end

    def initialize(argv, out: nil, err: nil)
      @argv = argv.dup
      @out = out
      @err = err
      @options = {
        id: nil,
        until_state: nil,
        repo_path: Dir.pwd,
        timeout: nil,
        heartbeat: nil,
        stall_after: nil,
        after_seq: nil,
        since: nil,
        help: false
      }
    end

    def run
      @out ||= $stdout
      @err ||= $stderr
      parser.parse!(@argv)
      if @options[:help]
        @out.puts self.class.usage
        return 0
      end

      raise "--id is required for harnex wait" unless @options[:id]
      if @options[:stall_after] && @options[:until_state] != "done"
        raise OptionParser::InvalidOption, "--stall-after requires --until done"
      end
      if @options[:after_seq] && !(["done"] + EVENT_PREDICATES).include?(@options[:until_state])
        raise OptionParser::InvalidOption, "--after-seq requires --until done, task_complete, or task_failed"
      end

      @started_at = monotonic
      @observation = { "state" => "unknown", "last_event" => "unknown", "seq" => nil }
      if @options[:timeout] || @options[:heartbeat]
        observe_in_child
      else
        wait
      end
    end

    private

    def wait
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

    # Only the read-side observer runs in this child, never the session or any
    # stop/marker action. A process boundary lets the parent enforce its cap
    # during blocking Ruby/HTTP probes, even probes with slow ensure clauses or
    # broad rescue handlers. No asynchronous Ruby exception crosses a probe.
    # The private process group also contains repo-resolution subprocesses.
    def observe_in_child
      reader, writer = IO.pipe
      writer.sync = true
      pid = fork do
        exit_code = 1
        begin
          Process.setpgid(0, 0)
          reader.close
          @observation_writer = writer
          @out = StringIO.new
          @err = DiagnosticStream.new { |text| send_observation_message(["warning", text]) }
          code = wait
          send_observation_message(["result", @out.string, code])
          exit_code = 0
        rescue Exception => error # transport errors too; never run inherited at_exit hooks
          begin
            send_observation_message(["error", error.class.name, error.message, error.backtrace])
          rescue IOError, SystemCallError
            nil # the caller may already have closed the pipe
          end
        ensure
          exit! exit_code
        end
      end
      writer.close
      deadline = @options[:timeout] && @started_at + @options[:timeout]
      next_heartbeat = @options[:heartbeat] && @started_at + @options[:heartbeat]
      buffer = +""

      loop do
        now = monotonic
        return emit_timeout if deadline && now >= deadline

        # Drain complete records without blocking on a partial pipe write.
        if (newline = buffer.index("\n"))
          message = JSON.parse(buffer.slice!(0..newline))
          case message[0]
          when "observation" then @observation = message[1]
          when "warning" then @err.write(message[1])
          when "result"
            return emit_timeout if deadline && monotonic >= deadline

            @out.write(message[1])
            return message[2]
          when "error"
            raise RuntimeError, "harnex wait observer: #{message[1]}: #{message[2]}", message[3]
          end
          next
        end

        if next_heartbeat && now >= next_heartbeat
          emit_heartbeat
          # Do not burst missed heartbeats after a scheduler pause.
          next_heartbeat = now + @options[:heartbeat]
        end
        wake_at = [deadline, next_heartbeat].compact.min
        # Clamp even finite enormous durations to an OS-safe select timeout.
        pause = [[wake_at - monotonic, 0].max, POLL_INTERVAL].min
        IO.select([reader], nil, nil, pause)
        chunk = reader.read_nonblock(16_384, exception: false)
        raise "harnex wait: observer exited without a result" if chunk.nil?

        buffer << chunk unless chunk == :wait_readable
      end
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
      reap_observer(pid) if pid
    end

    # SIGKILL bypasses slow Ruby ensure handlers. Reap without an unbounded
    # wait/join. Uninterruptible kernel I/O or a descheduled OS cannot be given
    # a universal preemption guarantee; no helper thread is left waiting on it.
    def reap_observer(pid)
      begin
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end
      cleanup_deadline = monotonic + EVENT_POLL_INTERVAL
      loop do
        return if Process.waitpid(pid, Process::WNOHANG)
        break if monotonic >= cleanup_deadline

        sleep 0.005
      end
      @err.puts("harnex wait: OS has not reaped the cancelled observer yet")
    rescue Errno::ECHILD
      nil
    end

    class DiagnosticStream
      def initialize(&write)
        @write = write
      end

      def write(text)
        @write.call(text)
      end

      def puts(text)
        write("#{text}\n")
      end
    end

    def send_observation_message(message)
      @observation_writer.write(JSON.generate(message) + "\n")
    end

    def observe(**fields)
      updated = @observation.merge(fields.transform_keys(&:to_s))
      return if updated == @observation

      @observation = updated
      send_observation_message(["observation", updated]) if @observation_writer
    end

    def emit_heartbeat
      # These are observations, not model/tool activity or a log-age proxy.
      values = %w[state last_event seq].map do |key|
        value = @observation[key] || "unknown"
        "#{key}=#{value.to_s.gsub(/[[:space:][:cntrl:]]/, '_')[0, 128]}"
      end
      @err.puts("harnex wait: id=#{@options[:id]} waited=#{(monotonic - @started_at).round(1)}s #{values.join(' ')}")
      @err.flush
    end

    def emit_timeout
      payload = { ok: false, id: @options[:id], status: "timeout",
                  waited_seconds: (monotonic - @started_at).round(1) }
      case @options[:until_state]
      when "done"
        payload.merge!(wait_result: "timeout", done: false,
                       work_state: @observation["live"] ? "running" : "unknown")
      when *EVENT_PREDICATES
        # Event waits retain their existing timeout payload shape.
      when nil
        payload[:pid] = @observation["pid"] if @observation["pid"]
      else
        payload[:state] = @observation["state"]
      end
      @out.puts JSON.generate(payload)
      DONE_EXIT_TIMEOUT
    end

    # All output goes through per-instance streams, including legacy wait
    # diagnostics. Resolve defaults in run so callers can still capture IO.
    def puts(text)
      @out.puts(text)
    end

    def warn(text)
      @err.puts(text)
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def wait_until_event(predicate)
      repo_root = Harnex.resolve_repo_root(@options[:repo_path])
      events_path = Harnex.events_log_path(repo_root, @options[:id])
      registry = Harnex.read_registry(repo_root, @options[:id])
      start_time = @started_at

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
      observe(state: "running", pid: target_pid) if target_pid

      loop do
        status, offset, task_complete_seen = scan_events(events_path, offset, predicate, task_complete_seen, start_time)
        return status if status

        if target_pid && !Harnex.alive_pid?(target_pid)
          observe(state: "exited")
          final_event_deadline ||= monotonic + FINAL_EVENT_GRACE_SECONDS
          if monotonic >= final_event_deadline
            waited = (monotonic - start_time).round(1)
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
          next if before_after_seq?(event)

          observe(last_event: event_type(event), seq: event["seq"])
          observe(state: event["state"]) if event_type(event) == "agent_state" && event["state"]
          task_complete_seen = true if %w[task_complete task_failed].include?(event_type(event))
          if matches?(event, predicate, task_complete_seen)
            return [emit_event_match(event, start_time, predicate), f.pos, task_complete_seen]
          end
        end
        offset = f.pos
      end

      [nil, offset, task_complete_seen]
    end

    # #81: events at or before --after-seq belong to an earlier turn. An event
    # without a seq cannot be placed after it, so it never matches either.
    def before_after_seq?(event)
      return false unless @options[:after_seq]

      seq = event["seq"]
      !seq.is_a?(Integer) || seq <= @options[:after_seq]
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
      waited = (monotonic - start_time).round(1)
      payload = {
        ok: true,
        id: @options[:id],
        event: event_type(event),
        seq: event["seq"],
        waited_seconds: waited
      }
      payload[:turn] = event["turn"] if event["turn"]
      payload[:follow_ups] = event["follow_ups"] if event["follow_ups"]
      %w[end_sha commits turn_commits model final_message final_message_path final_message_truncated].each do |key|
        payload[key.to_sym] = event[key] if event.key?(key)
      end
      exit_code = 0
      if predicate == "done"
        failed = done_event_failed?(event)
        outcome_class = event["outcome_class"] || stop_outcome_class(event["stop"])
        exit_code = failed ? done_failure_exit_code(outcome_class) : DONE_EXIT_DONE
        # A session seen gone by now has exited; one never observed stays
        # "running", the historical event-match default.
        exited = @observation["live"] == false
        payload.merge!(
          ok: !failed,
          status: failed ? "failed" : "done",
          wait_result: done_wait_result(exit_code),
          state: exited ? "exited" : "running",
          process_state: exited ? "exited" : "running",
          terminal: exited,
          task_complete: !failed,
          task_failed: failed,
          done: !failed,
          work_state: failed ? "failed" : "completed",
          outcome_class: outcome_class,
          artifact_report_status: event["artifact_report_status"]
        )
        payload[:last_error] = event["message"] || event["error"] if failed
        payload[:stop] = event["stop"] if event["stop"].is_a?(Hash)
      end
      puts JSON.generate(payload)
      exit_code
    end

    # A turn failed by a caller's stop or the runtime budget carries the
    # stop provenance, not a class; name it as the dispatch row will.
    def stop_outcome_class(stop)
      return nil unless stop.is_a?(Hash)

      { "manual" => "stopped_by_caller", "runtime_budget" => "timeout" }[stop["reason"].to_s]
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
      start_time = @started_at

      offset = 0
      task_complete_seen = false
      observed_live = nil
      session_started_at = nil
      next_stall_check = nil

      loop do
        live = live_session(repo_root)
        observe(state: live ? "running" : "unknown", pid: live && live["pid"], live: !!live)
        if live
          observed_live = live
          session_started_at ||= parse_wait_time(live["started_at"])
        end

        status, offset, task_complete_seen =
          scan_events(events_path, offset, "done", task_complete_seen, start_time, min_ts: done_min_ts(session_started_at))
        return status if status

        if @options[:stall_after] && live && (next_stall_check.nil? || monotonic >= next_stall_check)
          next_stall_check = monotonic + stall_poll_interval
          stall = Harnex::Stall.stalled(fetch_status_payload(live), @options[:stall_after])
          return emit_stall(stall, start_time) if stall
        end

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

        sleep EVENT_POLL_INTERVAL
      end
    end

    def done_min_ts(session_started_at)
      [session_started_at, @options[:since]].compact.max
    end

    def stall_poll_interval
      [[@options[:stall_after] / 4.0, 0.5].max, STALL_POLL_MAX_INTERVAL].min
    end

    # Only a registry row has the live API; start-record liveness cannot be
    # probed, so a stall stays unobserved there rather than guessed.
    def fetch_status_payload(live)
      return nil unless live["host"] && live["port"]

      uri = URI("http://#{live['host']}:#{live['port']}/status")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{live['token']}" if live["token"]
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 2) { |http| http.request(request) }
      return nil unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue StandardError
      nil
    end

    # The worker is left running: this is an observer verdict, like a timeout.
    def emit_stall(stall, start_time)
      waited = (monotonic - start_time).round(1)
      warn("harnex wait: #{@options[:id]} shows no progress for #{stall['idle_s'].round}s " \
           "(clock=#{stall['clock']}, threshold #{stall['threshold_s'].round}s); worker left running")
      puts JSON.generate(ok: false, id: @options[:id], status: "stalled", wait_result: "stalled",
                         state: "running", process_state: "running", terminal: false, task_complete: false,
                         done: false, work_state: "running", stall: stall, waited_seconds: waited)
      DONE_EXIT_STALLED
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
        scan_events(events_path, offset, "done", task_complete_seen, start_time, min_ts: done_min_ts(session_started_at))
      return status if status

      if File.exist?(exit_path) && fresh_exit_status?(exit_path, observed_live, session_started_at)
        return emit_done_exit_status(exit_path, @options[:id])
      end

      terminal = done_status(repo_root, min_started_at: session_started_at)
      return emit_done_terminal_status(terminal) if terminal

      waited = (monotonic - start_time).round(1)
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
      start_time = @started_at

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
          waited = (monotonic - start_time).round(1)
          puts JSON.generate(ok: false, id: @options[:id], state: "exited", waited_seconds: waited)
          return 1
        end

        state = fetch_agent_state(host, port, token)
        observe(state: state || "unknown", pid: target_pid)
        if state == target_state
          waited = (monotonic - start_time).round(1)
          puts JSON.generate(ok: true, id: @options[:id], state: state, waited_seconds: waited)
          return 0
        end

        sleep POLL_INTERVAL
      end
    end

    def wait_until_exit
      repo_root = Harnex.resolve_repo_root(@options[:repo_path])
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
      observe(state: "running", pid: target_pid)
      warn("harnex wait: watching session #{@options[:id]} (pid #{target_pid})")
      hint = exit_wait_hint(repo_root, registry)

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

        if hint && (settled = settled_event_type(hint))
          warn("harnex wait: note: #{@options[:id]} reached #{settled} but is still alive; " \
               "this wait still returns only on process exit. Use --until done for a work-level fence.")
          hint = nil
        end

        sleep POLL_INTERVAL
      end
    end

    # A bare wait fences process exit, but an interactive session stays alive
    # at its prompt after a turn. Say so on entry, and once more if the turn
    # settles mid-wait, so a waiter on the wrong predicate learns it before
    # its timeout (#49). --auto-stop sessions exit on their own: no hint.
    # Returns the event-scan cursor for the mid-wait check, or nil when done.
    def exit_wait_hint(repo_root, registry)
      return nil if registry["auto_stop"] == true

      cursor = {
        path: Harnex.events_log_path(repo_root, @options[:id]),
        offset: 0,
        min_ts: parse_wait_time(registry["started_at"])
      }
      if (settled = settled_event_type(cursor))
        warn("harnex wait: note: #{@options[:id]} already reached #{settled} and stays alive at its prompt; " \
             "this wait returns only on process exit. Use --until done for a work-level fence.")
        return nil
      end

      reason =
        if registry["auto_stop"] == false
          "was not started with --auto-stop, so it stays alive after its turn"
        else
          "may stay alive at its prompt after its turn unless started with --auto-stop"
        end
      warn("harnex wait: note: #{@options[:id]} #{reason}; this wait returns only on process exit. " \
           "Use --until done for a work-level fence.")
      cursor
    end

    def settled_event_type(cursor)
      path = cursor[:path]
      return nil unless File.exist?(path) && File.size(path) > cursor[:offset]

      File.open(path, "r") do |f|
        f.seek(cursor[:offset])
        f.each_line do |line|
          # Only whole lines advance the cursor; a partial tail is re-read.
          break unless line.end_with?("\n")

          cursor[:offset] = f.pos
          event = parse_event(line)
          next unless event
          next if stale_event?(event, cursor[:min_ts])

          type = event_type(event)
          return type if %w[task_complete task_failed].include?(type)
        end
      end
      nil
    end

    # Subprocess death races the parent's DISPATCH-row write; the exit-status
    # file is written *after* the row, so polling it bounds the race.
    def await_exit_status(exit_path)
      return if File.exist?(exit_path)

      grace_deadline = monotonic + exit_status_grace_seconds
      until File.exist?(exit_path) || monotonic >= grace_deadline
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
        stop: status["stop"],
        runtime_budget: status["runtime_budget"],
        exit: status["exit"],
        exit_code: status["exit_code"],
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
        opts.on("--timeout DUR", "Hard observer cap") do |value|
          @options[:timeout] = self.class.duration(value, option_name: "--timeout")
        end
        opts.on("--max-wait DUR", "Alias for --timeout") do |value|
          @options[:timeout] = self.class.duration(value, option_name: "--max-wait")
        end
        opts.on("--heartbeat DUR", "Flush progress to stderr") do |value|
          @options[:heartbeat] = self.class.duration(value, option_name: "--heartbeat")
        end
        opts.on("--after-seq N", Integer, "Ignore events at or before events-log seq N") do |value|
          raise OptionParser::InvalidArgument, "--after-seq must be 0 or greater" if value.negative?

          @options[:after_seq] = value
        end
        opts.on("--since TIME", "With --until done: ignore events before TIME") do |value|
          @options[:since] = parse_wait_time(value) ||
                             raise(OptionParser::InvalidArgument, "--since must be an ISO 8601 time")
        end
        opts.on("--stall-after DUR", "With --until done: exit 4 after DUR without progress") do |value|
          @options[:stall_after] = self.class.duration(value, option_name: "--stall-after")
        end
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end
  end
end
