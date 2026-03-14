require "json"
require "net/http"
require "optparse"
require "uri"

module Harnex
  class Exiter
    def self.usage(program_name = "harnex exit")
      <<~TEXT
        Usage: #{program_name} [options]

        Options:
          --id ID         Session ID to exit (required)
          --repo PATH     Resolve session using PATH's repo root (default: current repo)
          --cli CLI       Filter by CLI type (#{Adapters.supported.join(', ')})
          -h, --help      Show this help

        Sends the adapter-appropriate exit sequence to the session.
        Use `harnex wait --id ID` afterward to block until the session finishes.
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {
        id: Harnex.configured_id,
        repo_path: Dir.pwd,
        cli: nil,
        help: false
      }
    end

    def run
      parser.parse!(@argv)
      if @options[:help]
        puts self.class.usage
        return 0
      end

      raise "--id is required for harnex exit" unless @options[:id]

      repo_root = Harnex.resolve_repo_root(@options[:repo_path])
      registry = Harnex.read_registry(repo_root, @options[:id], cli: @options[:cli])
      unless registry
        warn("harnex exit: no session found with id #{@options[:id].inspect}")
        return 1
      end

      uri = URI("http://#{registry.fetch('host')}:#{registry.fetch('port')}/exit")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{registry['token']}" if registry["token"]

      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 5) do |http|
        http.request(request)
      end

      puts response.body
      response.is_a?(Net::HTTPSuccess) ? 0 : 1
    end

    private

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: harnex exit [options]"
        opts.on("--id ID", "Session ID to exit") { |value| @options[:id] = Harnex.normalize_id(Harnex.ensure_option_value!("--id", value)) }
        opts.on("--repo PATH", "Resolve session using PATH's repo root") { |value| @options[:repo_path] = Harnex.ensure_option_value!("--repo", value) }
        opts.on("--cli CLI", Adapters.supported, "Filter by CLI type") { |value| @options[:cli] = value }
        opts.on("-h", "--help", "Show help") { @options[:help] = true }
      end
    end
  end
end
