require "time"

module Harnex
  class CompletionNotifier
    WORK_STATES = {
      "completed" => "completed", "rejected" => "failed",
      "failed" => "failed", "error" => "failed"
    }.freeze

    def initialize(repo_root:, id:, session_id:, receipt_path:, hook_command: nil,
                   started_at: Time.now, clock: nil, event_sink: nil, spawn: nil,
                   detach: nil, atomic_write: nil, remove: nil, stderr: $stderr)
      @repo_root = Harnex.canonical_repo_root(repo_root)
      @id = Harnex.normalize_id(id)
      @session_id = session_id.to_s
      @receipt_path = receipt_path.to_s
      @hook_command = hook_command.to_s
      @hook_command = nil if @hook_command.empty?
      @started_at = started_at
      @clock = clock || -> { Time.now }
      @event_sink = event_sink
      @spawn = spawn || method(:spawn_hook)
      @detach = detach || ->(pid) { Process.detach(pid) }
      @atomic_write = atomic_write || Harnex.method(:atomic_write_json)
      @remove = remove || ->(path) { FileUtils.rm_f(path) }
      @stderr = stderr
      @mutex = Mutex.new
      @registered = false
      @notified = false
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
        @registered = true
      end
      true
    end

    def notify(outcome:, work_state:, outcome_class:, artifact_report_status:,
               end_sha:, terminal_signal:)
      outcome = outcome.to_s
      work_state = work_state.to_s
      expected = WORK_STATES[outcome]
      raise ArgumentError, "unsupported completion outcome #{outcome.inspect}" unless expected
      raise ArgumentError, "#{outcome.inspect} completion requires work_state #{expected.inspect}" unless work_state == expected
      return false unless @mutex.synchronize do
        @registered && !@notified ? (@notified = true) : false
      end

      now = @clock.call
      path = Harnex.completion_marker_path(@repo_root, @id, outcome)
      payload = {
        schema_version: 1, id: @id, session_id: @session_id,
        repo_root: @repo_root, outcome: outcome, work_state: work_state,
        outcome_class: optional_string(outcome_class),
        artifact_report_status: optional_string(artifact_report_status),
        receipt_path: @receipt_path, end_sha: optional_string(end_sha),
        elapsed_s: elapsed_seconds(now), terminal_signal: terminal_signal.to_s,
        notified_at: now.utc.iso8601
      }
      marker_written = write_marker(path, payload)
      hook_launched = launch_hook(payload)
      emit("completion_notification", outcome: outcome, work_state: work_state,
           marker_path: path, marker_written: marker_written,
           hook_configured: !@hook_command.nil?, hook_launched: hook_launched)
      true
    end

    private

    def optional_string(value)
      text = value.to_s
      text.empty? ? nil : text
    end

    def elapsed_seconds(now)
      [(now - @started_at).to_i, 0].max
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
