require "fileutils"
require "json"
require "net/http"
require "optparse"
require "stringio"
require "uri"

module Harnex
  class RunWatcher
    DEFAULT_STALL_AFTER_S = 8 * 60.0
    DEFAULT_MAX_RESUMES = 1
    POLL_INTERVAL_S = 60.0
    MAX_STATUS_ERRORS = 3
    RESUME_TEXT = "resume"

    def initialize(
      id:,
      repo_root:,
      stall_after_s: DEFAULT_STALL_AFTER_S,
      max_resumes: DEFAULT_MAX_RESUMES,
      poll_interval_s: POLL_INTERVAL_S,
      sleeper: nil,
      monotonic_clock: nil,
      out: $stdout,
      err: $stderr
    )
      @id = Harnex.normalize_id(id)
      @repo_root = repo_root
      @stall_after_s = Float(stall_after_s)
      @max_resumes = Integer(max_resumes)
      @poll_interval_s = Float(poll_interval_s)
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @out = out
      @err = err
    end

    def run
      polls = 0
      resumes = 0
      final_state = "unknown"
      outcome = :error
      status_errors = 0
      start_at = now

      @out.puts(
        "harnex watch: id=#{@id} stall-after=#{format_duration(@stall_after_s)} " \
        "max-resumes=#{@max_resumes} poll=#{format_duration(@poll_interval_s)}"
      )

      loop do
        polls += 1
        snapshot = fetch_snapshot

        case snapshot[:kind]
        when :exited
          final_state = "exited"
          outcome = :exited
          @out.puts("harnex watch: session exited")
          break
        when :error
          if snapshot[:fatal]
            @err.puts("harnex watch: #{snapshot[:error]}")
            outcome = :error
            break
          end

          status_errors += 1
          if status_errors >= MAX_STATUS_ERRORS
            @err.puts("harnex watch: #{snapshot[:error]} (status retry limit reached)")
            outcome = :error
            break
          end
        when :status
          status_errors = 0
          final_state = snapshot[:agent_state]

          if snapshot[:stalled]
            if resumes < @max_resumes
              send_resume(snapshot[:registry])
              resumes += 1
              @out.puts(
                "harnex watch: resume #{resumes}/#{@max_resumes} " \
                "(idle=#{format_duration(snapshot[:idle_seconds])}, state=#{final_state})"
              )
            else
              outcome = :escalated
              @out.puts("harnex watch: max resumes reached, escalating")
              break
            end
          end
        end

        @sleeper.call(@poll_interval_s)
      end

      elapsed = (now - start_at).round(1)
      @out.puts(
        "harnex watch: summary id=#{@id} polls=#{polls} resumes=#{resumes} " \
        "final_state=#{final_state} outcome=#{outcome} elapsed_s=#{elapsed}"
      )
      outcome_to_exit_code(outcome)
    rescue StandardError => e
      @err.puts("harnex watch: #{e.message}")
      1
    end

    private

    def fetch_snapshot
      registry = Harnex.read_registry(@repo_root, @id)
      return { kind: :exited } unless registry

      status = fetch_status(registry)
      return status if status[:kind] == :error

      payload = status[:payload]
      unless payload.key?("log_idle_s")
        return {
          kind: :error,
          fatal: true,
          error: "status payload missing log_idle_s; upgrade to a Layer-1+ harnex build"
        }
      end

      agent_state = payload["agent_state"].to_s.strip
      return { kind: :exited } if agent_state == "exited"

      idle_seconds = parse_idle_seconds(payload["log_idle_s"])
      {
        kind: :status,
        registry: registry,
        agent_state: agent_state.empty? ? "unknown" : agent_state,
        idle_seconds: idle_seconds,
        stalled: !idle_seconds.nil? && idle_seconds >= @stall_after_s
      }
    end

    def fetch_status(registry)
      uri = URI("http://#{registry.fetch('host')}:#{registry.fetch('port')}/status")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{registry['token']}" if registry["token"]

      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 1) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        return { kind: :error, error: "status request failed with HTTP #{response.code} for session #{@id}" }
      end

      { kind: :status_payload, payload: JSON.parse(response.body) }
    rescue StandardError => e
      { kind: :error, error: "status request failed for session #{@id}: #{e.message}" }
    end

    def send_resume(registry)
      uri = URI("http://#{registry.fetch('host')}:#{registry.fetch('port')}/send")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{registry['token']}" if registry["token"]
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(
        text: RESUME_TEXT,
        submit: true,
        enter_only: false,
        force: true
      )

      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 1) do |http|
        http.request(request)
      end

      return if response.is_a?(Net::HTTPSuccess)

      raise "resume send failed with HTTP #{response.code} for session #{@id}"
    rescue StandardError => e
      raise "resume send failed for session #{@id}: #{e.message}"
    end

    def parse_idle_seconds(value)
      return nil if value.nil?

      seconds = Integer(value)
      seconds.negative? ? 0 : seconds
    rescue StandardError
      nil
    end

    def outcome_to_exit_code(outcome)
      case outcome
      when :exited
        0
      when :escalated
        2
      else
        1
      end
    end

    def format_duration(seconds)
      value = seconds.to_f
      return "#{value.round(1)}s" if value < 60
      return "#{(value / 60).round(1)}m" if value < 3600

      "#{(value / 3600).round(1)}h"
    end

    def now
      @monotonic_clock.call
    end
  end

  class TerminalWatcher
    TIMEOUT_EXIT_CODE = 124

    def initialize(
      id:,
      repo_path: Dir.pwd,
      until_state: "done",
      max_wait: nil,
      done_marker: nil,
      fail_marker: nil,
      stop_on_terminal: false,
      out: $stdout,
      err: $stderr
    )
      @id = Harnex.normalize_id(id)
      @repo_path = repo_path
      @until_state = until_state.to_s.strip.empty? ? "done" : until_state.to_s
      @max_wait = max_wait
      @done_marker = done_marker
      @fail_marker = fail_marker
      @stop_on_terminal = stop_on_terminal
      @out = out
      @err = err
    end

    def run
      raise "harnex watch: only --until done is supported" unless @until_state == "done"

      output, warnings, exit_code = capture_wait
      @err.write(warnings) unless warnings.empty?
      @out.write(output) unless output.empty?

      payload = parse_payload(output)
      outcome = classify(exit_code, payload)
      case outcome
      when :success
        write_marker(@done_marker, payload, outcome: outcome, exit_code: exit_code)
      when :failed
        write_marker(@fail_marker, payload, outcome: outcome, exit_code: exit_code)
      end

      stop_session if @stop_on_terminal && outcome != :timeout
      exit_code
    end

    private

    def capture_wait
      argv = ["--id", @id, "--repo", @repo_path, "--until", @until_state]
      argv += ["--timeout", @max_wait.to_s] if @max_wait

      out_buffer = StringIO.new
      err_buffer = StringIO.new
      original_stdout = $stdout
      original_stderr = $stderr
      $stdout = out_buffer
      $stderr = err_buffer
      exit_code = Waiter.new(argv).run
      [out_buffer.string, err_buffer.string, exit_code]
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end

    def parse_payload(output)
      line = output.to_s.lines.reverse.find { |candidate| !candidate.strip.empty? }
      return {} unless line

      parsed = JSON.parse(line)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def classify(exit_code, payload)
      return :timeout if exit_code == TIMEOUT_EXIT_CODE || payload["status"].to_s == "timeout"
      return :success if exit_code.to_i.zero? && (payload.empty? || payload["ok"] != false)

      :failed
    end

    def write_marker(path, payload, outcome:, exit_code:)
      marker_path = path.to_s.strip
      return if marker_path.empty?

      expanded_path = File.expand_path(marker_path)
      FileUtils.mkdir_p(File.dirname(expanded_path))
      marker_payload = {
        ok: outcome == :success,
        id: @id,
        outcome: outcome.to_s,
        exit_code: exit_code,
        status: payload["status"],
        work_state: payload["work_state"],
        outcome_class: payload["outcome_class"],
        artifact_report_status: payload["artifact_report_status"],
        task_complete: payload["task_complete"] || payload["event"] == "task_complete",
        task_failed: payload["task_failed"] || payload["event"] == "task_failed",
        done: payload["done"],
        terminal: payload["terminal"],
        source: "harnex watch"
      }.compact
      File.write(expanded_path, JSON.generate(marker_payload) + "\n")
    end

    def stop_session
      repo_root = Harnex.resolve_repo_root(@repo_path)
      registry = Harnex.read_registry(repo_root, @id)
      return unless registry

      uri = URI("http://#{registry.fetch('host')}:#{registry.fetch('port')}/stop")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{registry['token']}" if registry["token"]

      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 2) do |http|
        http.request(request)
      end
      @err.puts("harnex watch: stop-on-terminal failed with HTTP #{response.code}") unless response.is_a?(Net::HTTPSuccess)
    rescue StandardError => e
      @err.puts("harnex watch: stop-on-terminal failed: #{e.message}")
    end
  end

  class WatchCommand
    def self.usage(program_name = "harnex watch")
      <<~TEXT
        Usage: #{program_name} --id ID [options]

        Options:
          --id ID              Existing session ID to watch (required)
          --until done         Watch work-level terminal state (default: done)
          --repo PATH          Resolve session using PATH's repo root (default: current repo)
          --max-wait DUR       Wall-clock cap before returning timeout (examples: 900, 15m, 2h)
          --timeout DUR        Alias for --max-wait
          --done-marker PATH   Write a JSON marker when work completes successfully
          --fail-marker PATH   Write a JSON marker when work fails
          --stop-on-terminal   Stop the live session after success/failure (not on timeout)
          -h, --help           Show this help

        `harnex watch` is the safe watcher for existing --tmux or detached
        dispatches. It exits 0 for task_complete/done, non-zero for task_failed
        or failed terminal summaries, and 124 for --max-wait timeouts.

        For launch-and-babysit stall recovery, use `harnex run --watch`.
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {
        id: nil,
        repo_path: Dir.pwd,
        until_state: "done",
        max_wait: nil,
        done_marker: nil,
        fail_marker: nil,
        stop_on_terminal: false,
        help: false
      }
    end

    def run
      parser.parse!(@argv)
      if @options[:help]
        puts self.class.usage
        return 0
      end

      raise "--id is required for harnex watch" unless @options[:id]

      TerminalWatcher.new(
        id: @options[:id],
        repo_path: @options[:repo_path],
        until_state: @options[:until_state],
        max_wait: @options[:max_wait],
        done_marker: @options[:done_marker],
        fail_marker: @options[:fail_marker],
        stop_on_terminal: @options[:stop_on_terminal]
      ).run
    end

    private

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: harnex watch --id ID [options]"
        opts.on("--id ID", "Existing session ID to watch") { |value| @options[:id] = Harnex.normalize_id(value) }
        opts.on("--until STATE", "Watch until terminal state") { |value| @options[:until_state] = value }
        opts.on("--repo PATH", "Resolve session using PATH's repo root") { |value| @options[:repo_path] = value }
        opts.on("--max-wait DUR", "Wall-clock cap") do |value|
          @options[:max_wait] = Harnex.parse_duration_seconds(value, option_name: "--max-wait")
        end
        opts.on("--timeout DUR", "Alias for --max-wait") do |value|
          @options[:max_wait] = Harnex.parse_duration_seconds(value, option_name: "--timeout")
        end
        opts.on("--done-marker PATH", "Write marker on successful completion") { |value| @options[:done_marker] = value }
        opts.on("--fail-marker PATH", "Write marker on failed completion") { |value| @options[:fail_marker] = value }
        opts.on("--stop-on-terminal", "Stop live session after success/failure") { @options[:stop_on_terminal] = true }
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end
  end
end
