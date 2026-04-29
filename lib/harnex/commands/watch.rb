require "json"
require "net/http"
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
end
