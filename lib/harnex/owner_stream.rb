require "json"
require "net/http"
require "time"
require "uri"

module Harnex
  # #77: `harnex watch --owner`. One compact JSON line per lifecycle change of
  # every dispatch an owner started, for a Claude Code `Monitor` or a panel.
  # Sources are the #72 owner records (registered `running`, then settled),
  # the dispatch row's #57 class for `error` settlements, and live status via
  # Harnex::Stall. Only event lines reach stdout; nothing is nudged or stopped.
  class OwnerStream
    SCHEMA = "harnex.owner_event.v1"
    EVENTS = %w[started done rejected failed stalled stopped timeout].freeze
    POLL_INTERVAL_S = 2.0
    # An `error` settlement precedes its dispatch row by milliseconds; give the
    # row this long to land before classifying without it.
    ROW_GRACE_S = 5.0
    STALL_POLL_MAX_INTERVAL_S = 15.0
    MAX_WAIT_EXIT = 124
    CURSOR_NAME = /\A[A-Za-z0-9._-]{1,64}\z/

    # once: (#84) exit 0 after the first event the cursor delivers (a result
    # or a stall), so one blocking call covers every lane. `started` lines
    # are skipped there: they repeat on every start and would end each call.
    # cursor: a named cursor, so a parent and its subagent (which share one
    # Claude session id) do not take each other's events.
    def initialize(owner_id:, stall_after: nil, max_wait: nil, once: false, cursor: nil, out: $stdout, err: $stderr,
                   clock: nil, wall_clock: nil, sleeper: nil, status_fetcher: nil)
      @owner_id = owner_id.to_s
      raise ArgumentError, "owner id is required" if @owner_id.strip.empty?
      if cursor && !cursor.to_s.match?(CURSOR_NAME)
        raise ArgumentError, "cursor name must be 1-64 letters, digits, '.', '_' or '-'"
      end

      @stall_after = stall_after
      @max_wait = max_wait
      @once = once
      @emitted = 0
      @out = out
      @err = err
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @wall_clock = wall_clock || -> { Time.now }
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @status_fetcher = status_fetcher || method(:fetch_status)
      @dir = Harnex.owned_notifications_dir(@owner_id)
      @cursor_path = File.join(@dir, "watch", cursor ? "cursor-#{cursor}.json" : "cursor.json")
      @running = {}
    end

    def run
      deadline = @max_wait && @clock.call + @max_wait
      load_cursor
      loop do
        scan
        return 0 if once_satisfied?
        if deadline && @clock.call >= deadline
          @err.puts("harnex watch: no owner event within #{duration(@max_wait)}") if @once
          return MAX_WAIT_EXIT
        end

        @sleeper.call(POLL_INTERVAL_S)
      end
    rescue Interrupt
      0
    end

    # One pass over the owner's records; public for deterministic tests.
    def scan
      load_cursor unless @delivered
      list = records
      seen = list.to_h { |record| [record["session_id"], true] }
      list.each do |record|
        break if once_satisfied?
        next if delivered?(record)

        if record["outcome"].to_s.empty?
          observe_running(record)
        else
          @running.delete(record["session_id"])
          settle(record)
        end
      end
      @running.select! { |session_id, _| seen[session_id] }
      prune_cursor(seen)
    end

    private

    def once_satisfied?
      @once && @emitted.positive?
    end

    # The cursor keeps one delivery key per dispatch: its latest delivered
    # turn result (#81), or the runner_gone report for its running turn.
    def delivered?(record)
      value = @delivered[record["session_id"]]
      return false if value.nil?
      # Any value for a first turn still running is its runner_gone report
      # (cursors written before #81 stored a timestamp there).
      return turn_of(record) <= 1 || value == gone_key(record) if record["outcome"].to_s.empty?

      value == settled_key(record)
    end

    def turn_of(record)
      [record["turn"].to_i, 1].max
    end

    # A first turn keys on notified_at alone, as cursors before #81 did.
    def settled_key(record)
      key = record["notified_at"].to_s
      key = "settled" if key.empty?
      turn_of(record) > 1 ? "#{key}##{turn_of(record)}" : key
    end

    def gone_key(record)
      "gone##{turn_of(record)}"
    end

    def records
      return [] unless File.directory?(@dir)

      Dir.glob(File.join(@dir, "*.json")).sort.filter_map do |path|
        record = JSON.parse(File.read(path))
        next unless record.is_a?(Hash) && record["owner_id"] == @owner_id
        next if record["session_id"].to_s.empty? || record["id"].to_s.empty?

        record
      rescue JSON::ParserError, Errno::ENOENT
        nil
      end
    end

    def observe_running(record)
      session_id = record["session_id"]
      state = @running[session_id]
      unless state
        state = @running[session_id] = { stalled: @stalled.key?(session_id), next_check: nil }
        # A later turn (a nudge) is watched silently; its result is reported.
        if turn_of(record) <= 1 && !@once
          emit("started", record, msg: "#{record['id']} started in #{portable(record['repo_root'])}")
        end
      end

      # A runner that died without settling will never write an outcome.
      pid = record["runner_pid"]
      if pid && !Harnex.alive_pid?(pid)
        emit("failed", record, reason: "runner_gone",
                               msg: "#{record['id']} failed: its harnex runner exited without a result")
        deliver(record, gone_key(record))
        @running.delete(session_id)
        return
      end

      check_stall(record, state) if @stall_after
    end

    def check_stall(record, state)
      now = @clock.call
      return if state[:next_check] && now < state[:next_check]

      state[:next_check] = now + [[@stall_after / 4.0, 0.5].max, STALL_POLL_MAX_INTERVAL_S].min
      stall = Harnex::Stall.stalled(@status_fetcher.call(record), @stall_after)
      if stall && !state[:stalled]
        state[:stalled] = true
        remember_stall(record["session_id"], true)
        emit("stalled", record, stall: stall,
                                msg: "#{record['id']} stalled: no progress for #{duration(stall['idle_s'])} (#{stall['clock']})")
      elsif stall.nil?
        state[:stalled] = false # progress resumed (or nothing observable): re-arm
        remember_stall(record["session_id"], false)
      end
    end

    # --once runs one process per event, so a stall episode must outlive the
    # process or every call would end on the same stall.
    def remember_stall(session_id, stalled)
      return unless @once
      return if @stalled.key?(session_id) == stalled

      stalled ? @stalled[session_id] = true : @stalled.delete(session_id)
      save_cursor
    end

    def settle(record)
      outcome = record["outcome"].to_s
      outcome_class = record["outcome_class"]
      event = { "completed" => "done", "rejected" => "rejected" }[outcome]
      if event.nil?
        # "failed"/"error": a stop or deadline can surface as either (Pi
        # settles an interrupted turn as failed). The dispatch row's #57
        # class names the cause; it lands moments after an auto-stop
        # settlement, so wait briefly for it before falling back.
        row = dispatch_row(record)
        return if row.nil? && within_row_grace?(record)

        outcome_class = row&.dig("outcome", "class") || outcome_class
        event = { "timeout" => "timeout", "stopped_by_caller" => "stopped" }.fetch(outcome_class.to_s, "failed")
      end

      emit(event, record, outcome_class: outcome_class, msg: settled_message(event, record, outcome_class))
      deliver(record, settled_key(record))
    end

    def settled_message(event, record, outcome_class)
      id = record["id"]
      id = "#{id} turn #{turn_of(record)}" if turn_of(record) > 1
      after = record["elapsed_s"] ? " after #{duration(record['elapsed_s'])}" : ""
      case event
      when "done" then "#{id} done (#{outcome_class || 'completed'})#{after}"
      when "rejected" then "#{id} rejected: #{outcome_class || 'proof rejected'}#{after}"
      when "timeout" then "#{id} hit its runtime budget#{after}"
      when "stopped" then "#{id} stopped by its caller#{after}"
      else "#{id} failed (#{outcome_class || 'unknown'})#{after}"
      end
    end

    def emit(event, record, msg:, outcome_class: nil, stall: nil, reason: nil)
      line = {
        "schema" => SCHEMA,
        "event" => event,
        "id" => record["id"],
        "session_id" => record["session_id"],
        "turn" => (turn_of(record) if record.key?("turn")),
        "repo" => portable(record["repo_root"]),
        "ts" => @wall_clock.call.utc.iso8601(3),
        "work_state" => { "started" => "running", "stalled" => "running", "done" => "completed" }.fetch(event, "failed"),
        "outcome_class" => outcome_class,
        "artifact_report_status" => record["artifact_report_status"],
        "receipt_path" => portable(record["receipt_path"]),
        "end_sha" => record["end_sha"],
        "elapsed_s" => record["elapsed_s"],
        "settled_at" => (record["notified_at"] if record["outcome"]),
        "follow_ups" => record["follow_ups"],
        "stall" => stall,
        "reason" => reason,
        "msg" => msg
      }.compact
      @out.puts(JSON.generate(line))
      @out.flush
      @emitted += 1
    end

    def deliver(record, key)
      @delivered[record["session_id"]] = key
      save_cursor
    end

    def within_row_grace?(record)
      notified = Time.iso8601(record["notified_at"].to_s)
      @wall_clock.call - notified < ROW_GRACE_S
    rescue ArgumentError
      false
    end

    def dispatch_row(record)
      path = Harnex::DispatchHistory.path_for(record["repo_root"].to_s)
      return nil unless File.file?(path)

      File.readlines(path).reverse_each do |line|
        row = JSON.parse(line)
        return row if Harnex::DispatchHistory.end_record?(row) && row["session_id"] == record["session_id"]
      rescue JSON::ParserError
        next
      end
      nil
    end

    # Live status for this exact attempt: a reused id must not be mistaken
    # for the dispatch the record describes.
    def fetch_status(record)
      registry = Harnex.read_registry(record["repo_root"].to_s, record["id"])
      return nil unless registry && registry["session_id"] == record["session_id"]

      uri = URI("http://#{registry['host']}:#{registry['port']}/status")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{registry['token']}" if registry["token"]
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 2) { |http| http.request(request) }
      response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body) : nil
    rescue StandardError
      nil
    end

    def load_cursor
      data = JSON.parse(File.read(@cursor_path))
      @delivered = data["delivered"].is_a?(Hash) ? data["delivered"] : {}
      @stalled = data["stalled"].is_a?(Hash) ? data["stalled"] : {}
    rescue Errno::ENOENT, JSON::ParserError
      @delivered = {}
      @stalled = {}
    end

    def save_cursor
      FileUtils.mkdir_p(File.dirname(@cursor_path), mode: 0o700)
      state = { schema_version: 1, delivered: @delivered }
      state[:stalled] = @stalled unless @stalled.empty?
      Harnex.atomic_write_json(@cursor_path, state)
    rescue StandardError => e
      @err.puts("harnex watch: could not save the owner cursor (#{e.class}); results may repeat after a restart")
    end

    # Records outlive delivery; drop cursor entries only for vanished records.
    def prune_cursor(seen)
      stale = @delivered.keys.reject { |session_id| seen[session_id] }
      gone_stalls = @stalled.keys.reject { |session_id| seen[session_id] }
      return if stale.empty? && gone_stalls.empty?

      stale.each { |session_id| @delivered.delete(session_id) }
      gone_stalls.each { |session_id| @stalled.delete(session_id) }
      save_cursor
    end

    def portable(path)
      return nil if path.nil? || path.to_s.empty?

      Harnex::DispatchHistory.portable_path(path.to_s)
    end

    def duration(seconds)
      value = seconds.to_f.round
      return "#{value}s" if value < 60
      return "#{(value / 60.0).round}m" if value < 3600

      hours, rest = value.divmod(3600)
      format("%dh%02dm", hours, rest / 60)
    end
  end
end
