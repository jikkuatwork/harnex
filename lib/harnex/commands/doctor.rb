require "json"

module Harnex
  class Doctor
    MIN_CODEX_VERSION = Gem::Version.new("0.128.0")

    def self.usage
      <<~TEXT
        Usage: harnex doctor

        Runs preflight checks for harnex's adapter dependencies.
        Currently verifies that Codex CLI is installed and at version
        >= #{MIN_CODEX_VERSION} (required for the JSON-RPC `app-server`
        adapter).
      TEXT
    end

    def initialize(argv = [])
      @argv = argv.dup
    end

    def run
      if @argv.include?("-h") || @argv.include?("--help")
        puts self.class.usage
        return 0
      end

      checks = [check_codex]
      summary = {
        ok: checks.all? { |c| c[:ok] },
        checks: checks
      }
      puts JSON.generate(summary)
      summary[:ok] ? 0 : 1
    end

    private

    def check_codex
      result = { name: "codex", required: ">= #{MIN_CODEX_VERSION}" }

      version_output, status = capture("codex --version")
      if status.nil?
        return result.merge(ok: false, error: "codex CLI not found on PATH")
      end
      unless status.success?
        return result.merge(ok: false, error: "codex --version failed: #{version_output.strip}")
      end

      version = parse_version(version_output)
      if version.nil?
        return result.merge(ok: false, found: version_output.strip, error: "could not parse codex version output")
      end

      if version < MIN_CODEX_VERSION
        return result.merge(ok: false, found: version.to_s,
                            error: "codex #{version} < required #{MIN_CODEX_VERSION}; upgrade with `npm i -g @openai/codex` or your platform package manager")
      end

      result.merge(ok: true, found: version.to_s)
    end

    def capture(command)
      output = `#{command} 2>&1`
      [output, $?]
    rescue StandardError => e
      [e.message, nil]
    end

    def parse_version(text)
      match = text.match(/(\d+\.\d+\.\d+)/)
      match ? Gem::Version.new(match[1]) : nil
    end
  end
end
