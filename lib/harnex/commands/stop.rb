require "json"
require "net/http"
require "optparse"
require "uri"

module Harnex
  class Stopper
    DEFAULT_TIMEOUT = 5.0
    MIN_HTTP_TIMEOUT = 0.1

    class TimeoutError < RuntimeError; end

    def self.usage(program_name = "harnex stop")
      <<~TEXT
        Usage: #{program_name} [options]

        Options:
          --id ID      Session ID to stop (required)
          --repo PATH  Resolve the session using PATH's repo root (default: current repo)
          --cli CLI    Filter by CLI type
          --timeout S  How long to retry transient API failures (default: #{DEFAULT_TIMEOUT})
          -h, --help   Show this help

        Sends the adapter stop sequence to the session.
        Use `harnex wait --id ID` afterward to block until the session finishes.

        Common patterns:
          #{program_name} --id cx-i-42
          #{program_name} --id cx-i-42 --repo /path/to/repo
          #{program_name} --id cx-i-42 --timeout 15

        Gotchas:
          Stop only after verifying the worker's result landed.
          For tmux sessions, stop targets the harnex session ID, not the tmux name.
          If a session is in another repo/worktree, pass --repo or run status --all.
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {
        id: nil,
        repo_path: Dir.pwd,
        cli: nil,
        timeout: DEFAULT_TIMEOUT,
        help: false
      }
    end

    def run
      parser.parse!(@argv)
      if @options[:help]
        puts self.class.usage
        return 0
      end

      raise "--id is required for harnex stop" unless @options[:id]

      repo_root = Harnex.resolve_repo_root(@options[:repo_path])
      registry = Harnex.read_registry(repo_root, @options[:id], cli: @options[:cli])
      unless registry
        warn("harnex stop: no session found with id #{@options[:id].inspect}")
        return 1
      end

      uri = URI("http://#{registry.fetch('host')}:#{registry.fetch('port')}/stop")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{registry['token']}" if registry["token"]

      deadline = monotonic_now + @options[:timeout]
      response = with_http_retry(deadline: deadline) do
        Net::HTTP.start(
          uri.host,
          uri.port,
          open_timeout: http_timeout(deadline, cap: 1.0),
          read_timeout: http_timeout(deadline, cap: 2.0)
        ) { |http| http.request(request) }
      end

      parsed = parse_json_body(response.body)
      puts JSON.generate(parsed)
      response.is_a?(Net::HTTPSuccess) && parsed["error"].nil? ? 0 : 1
    rescue TimeoutError => e
      puts JSON.generate(ok: false, id: @options[:id], status: "timeout", error: e.message)
      124
    end

    private

    def with_http_retry(deadline:)
      loop do
        raise TimeoutError, timeout_message if deadline_reached?(deadline)

        return yield
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, EOFError, Net::ReadTimeout, Net::OpenTimeout
        raise TimeoutError, timeout_message if deadline_reached?(deadline)

        sleep 0.1
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def deadline_reached?(deadline)
      monotonic_now >= deadline
    end

    def http_timeout(deadline, cap: nil)
      remaining = deadline - monotonic_now
      remaining = [remaining, MIN_HTTP_TIMEOUT].max
      cap ? [remaining, cap].min : remaining
    end

    def timeout_message
      "request timed out after #{@options[:timeout]}s"
    end

    def parse_json_body(body)
      JSON.parse(body.to_s.empty? ? "{}" : body.to_s)
    rescue JSON::ParserError
      { "ok" => false, "error" => "invalid json response", "raw_body" => body.to_s }
    end

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: harnex stop [options]"
        opts.on("--id ID", "Session ID to stop") { |value| @options[:id] = Harnex.normalize_id(value) }
        opts.on("--repo PATH", "Resolve the session using PATH's repo root") { |value| @options[:repo_path] = value }
        opts.on("--cli CLI", "Filter by CLI type") { |value| @options[:cli] = value }
        opts.on("--timeout SECS", Float, "How long to retry transient API failures") { |value| @options[:timeout] = value }
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end
  end
end
