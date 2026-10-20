require "time"

module Harnex
  class CompletionNotifier
    class RegistrationError < StandardError; end

    # Per-turn results kept in the owner record, so a watcher that was away
    # while several turns ended still receives each one.
    MAX_RESULTS = 20
    WORK_STATES = {
      "completed" => "completed", "rejected" => "failed",
      "failed" => "failed", "error" => "failed"
    }.freeze

    def initialize(repo_root:, id:, session_id:, receipt_path:, hook_command: nil, owner_id: nil,
                   started_at: Time.now, clock: nil, event_sink: nil, spawn: nil,
                   detach: nil, atomic_write: nil, remove: nil, stderr: $stderr)
      @repo_root = Harnex.canonical_repo_root(repo_root)
      @id = Harnex.normalize_id(id)
      @session_id = session_id.to_s
      @receipt_path = receipt_path.to_s
      @owner_id = owner_id.to_s.strip
      @owner_id = nil if @owner_id.empty?
      @hook_command = hook_command.to_s
      @hook_command = nil if @hook_command.empty?
      @started_at = started_at
      @turn_started_at = started_at
      @clock = clock || -> { Time.now }
      @event_sink = event_sink
      @spawn = spawn || method(:spawn_hook)
      @detach = detach || ->(pid) { Process.detach(pid) }
      @atomic_write = atomic_write || Harnex.method(:atomic_write_json)
      @remove = remove || ->(path) { FileUtils.rm_f(path) }
      @stderr = stderr
      @mutex = Mutex.new
      @registered = false
      @notified_turn = 0
      @results = []
    end

    # Registration is the stale-marker boundary for a reused repo/id pair.
    def register!
      @mutex.synchronize do
        return true if @registered

        Harnex.completion_marker_paths(@repo_root, @id).each do |path|
          @remove.call(path)
        rescue StandardError => e
          report_error("completion marker cleanup failed", "cleanup", e, path: path)
        end
        register_owned_delivery!
        @registered = true
      end
      true
    end

    # One result per turn (#81). The owner record is rewritten for every turn
    # so `watch --owner` reports a nudged turn too; the marker files and the
    # --on-done hook keep their documented once-per-session contract.
    def notify(outcome:, work_state:, outcome_class:, artifact_report_status:,
               end_sha:, terminal_signal:, turn: 1, follow_ups: nil,
               final_message: nil, final_message_path: nil, turn_details: nil)
      outcome = outcome.to_s
      work_state = work_state.to_s
      turn = [turn.to_i, 1].max
      expected = WORK_STATES[outcome]
      raise ArgumentError, "unsupported completion outcome #{outcome.inspect}" unless expected
      raise ArgumentError, "#{outcome.inspect} completion requires work_state #{expected.inspect}" unless work_state == expected
      first = nil
      return false unless @mutex.synchronize do
        next false unless @registered && turn > @notified_turn

        first = @notified_turn.zero?
        @notified_turn = turn
        true
      end

      now = @clock.call
      path = Harnex.completion_marker_path(@repo_root, @id, outcome)
      payload = {
        schema_version: 1, id: @id, session_id: @session_id,
        repo_root: @repo_root, outcome: outcome, work_state: work_state,
        outcome_class: optional_string(outcome_class),
        artifact_report_status: optional_string(artifact_report_status),
        receipt_path: @receipt_path, end_sha: optional_string(end_sha),
        elapsed_s: elapsed_seconds(now, first ? @started_at : @turn_started_at),
        terminal_signal: terminal_signal.to_s, notified_at: now.utc.iso8601
      }
      marker_written = first ? write_marker(path, payload) : false
      if @owner_id
        result = payload.slice(:outcome, :work_state, :outcome_class, :artifact_report_status,
                               :end_sha, :elapsed_s, :terminal_signal, :notified_at).merge(turn: turn)
        result[:follow_ups] = follow_ups if follow_ups
        result[:final_message] = final_message if final_message
        result[:final_message_path] = final_message_path if final_message_path
        result.merge!(turn_details.compact) if turn_details.is_a?(Hash)
        results = @mutex.synchronize do
          @results << result
          @results.shift while @results.length > MAX_RESULTS
          @results.dup
        end
        write_owned_delivery(payload.merge(result).merge(results: results))
      end
      hook_launched = first ? launch_hook(payload) : false
      emit("completion_notification", outcome: outcome, work_state: work_state, turn: turn,
           marker_path: path, marker_written: marker_written,
           hook_configured: !@hook_command.nil?, hook_launched: hook_launched)
      true
    end

    # A message injected after a published result starts the next turn: the
    # owner record returns to running so the stream watches it again.
    def turn_started(turn)
      @turn_started_at = @clock.call
      return false unless @owner_id && @mutex.synchronize { @registered }

      path = Harnex.owned_notification_path(@owner_id, @session_id)
      results = @mutex.synchronize { @results.dup }
      @atomic_write.call(path, owned_identity.merge(work_state: "running", turn: [turn.to_i, 1].max,
                                                    turn_started_at: @turn_started_at.utc.iso8601, results: results))
      true
    rescue StandardError => e
      report_error("owned notification turn update failed", "delivery", e)
      false
    end

    private

    def owned_identity
      {
        schema_version: 1, owner_id: @owner_id, id: @id, session_id: @session_id,
        repo_root: @repo_root, receipt_path: @receipt_path,
        runner_pid: Process.pid, started_at: @started_at.utc.iso8601
      }
    end

    def register_owned_delivery!
      return unless @owner_id

      path = Harnex.owned_notification_path(@owner_id, @session_id)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      @atomic_write.call(path, owned_identity.merge(work_state: "running"))
    rescue StandardError => e
      report_error("owned notification registration failed", "registration", e)
      raise RegistrationError, "cannot register owned completion delivery (#{e.class})"
    end

    def write_owned_delivery(payload)
      path = Harnex.owned_notification_path(@owner_id, @session_id)
      @atomic_write.call(path, owned_identity.merge(payload))
    rescue StandardError => e
      # The running record remains: its owner can still reconcile with native
      # watch/receipt evidence, independently of this push write or the hook.
      report_error("owned notification write failed", "delivery", e)
    end

    def optional_string(value)
      text = value.to_s
      text.empty? ? nil : text
    end

    # A later turn's elapsed time runs from that turn's start.
    def elapsed_seconds(now, since = @started_at)
      [(now - since).to_i, 0].max
    rescue StandardError
      0
    end

    def write_marker(path, payload)
      @atomic_write.call(path, payload)
      true
    rescue StandardError => e
      report_error("completion marker write failed", "marker", e, path: path)
      false
    end

    def launch_hook(payload)
      return false unless @hook_command

      env = {
        "HARNEX_ID" => @id,
        "HARNEX_OUTCOME" => payload.fetch(:outcome),
        "HARNEX_WORK_STATE" => payload.fetch(:work_state),
        "HARNEX_RECEIPT_PATH" => @receipt_path,
        "HARNEX_END_SHA" => payload[:end_sha].to_s,
        "HARNEX_ELAPSED_S" => payload.fetch(:elapsed_s).to_s
      }
      pid = @spawn.call(env, @hook_command, {
        chdir: @repo_root, in: File::NULL, out: @stderr, err: @stderr
      })
      @detach.call(pid)
      true
    rescue StandardError => e
      report_error("completion hook launch failed", "hook", e)
      false
    end

    def spawn_hook(env, command, options)
      Process.spawn(env, "/bin/sh", "-c", command, **options)
    end

    # Do not include exception messages: injected spawn failures can echo CMD.
    def report_error(message, component, error, path: nil)
      @stderr.puts("harnex: #{message} (#{error.class})") rescue nil
      payload = { component: component, error_class: error.class.name }
      payload[:path] = path if path
      emit("completion_notification_error", **payload)
    end

    def emit(type, **payload)
      @event_sink&.call(type, payload)
    rescue StandardError => e
      @stderr.puts("harnex: completion diagnostic event failed (#{e.class})") rescue nil
    end
  end
end
