require "json"
require "net/http"
require "optparse"
require "uri"

module Harnex
  class Waiter
    POLL_INTERVAL = 0.5

    def self.usage(program_name = "harnex wait")
      <<~TEXT
        Usage: #{program_name} [options]

        Options:
          --id ID         Session ID to wait for (required)
          --until STATE   Wait until session reaches STATE (e.g. "prompt")
                          Without --until, waits for session exit (default)
          --repo PATH     Resolve session using PATH's repo root (default: current repo)
          --timeout SECS  Maximum time to wait in seconds (default: unlimited)
          -h, --help      Show this help
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
        wait_until_state
      else
        wait_until_exit
      end
    end

    private

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

        warn("harnex wait: no session found with id #{@options[:id].inspect}")
        return 1
      end

      target_pid = registry["pid"]
      warn("harnex wait: watching session #{@options[:id]} (pid #{target_pid})")

      loop do
        unless Harnex.alive_pid?(target_pid)
          return read_exit_status(exit_path, @options[:id])
        end

        if deadline && Time.now >= deadline
          puts JSON.generate(ok: false, id: @options[:id], status: "timeout", pid: target_pid)
          return 124
        end

        sleep POLL_INTERVAL
      end
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

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: harnex wait [options]"
        opts.on("--id ID", "Session ID to wait for") { |value| @options[:id] = Harnex.normalize_id(Harnex.ensure_option_value!("--id", value)) }
        opts.on("--until STATE", "Wait until session reaches STATE") { |value| @options[:until_state] = Harnex.ensure_option_value!("--until", value) }
        opts.on("--repo PATH", "Resolve session using PATH's repo root") { |value| @options[:repo_path] = Harnex.ensure_option_value!("--repo", value) }
        opts.on("--timeout SECONDS", Float, "Maximum time to wait") { |value| @options[:timeout] = value }
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end
  end
end
