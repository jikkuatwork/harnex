require "json"

module Harnex
  module Config
    CONFIG_RELATIVE_PATH = File.join(".harnex", "config.json").freeze
    PHASE_POLICIES = %w[warn reject].freeze

    ConfigError = Class.new(StandardError)

    RepoConfig = Struct.new(:root, :path, :data, keyword_init: true) do
      def present?
        !path.nil? && File.file?(path)
      end

      def phase
        data.is_a?(Hash) ? data["phase"] : nil
      end
    end

    module_function

    def load_repo(start_path)
      root = DispatchHistory.find_git_root(start_path)
      return RepoConfig.new(root: nil, path: nil, data: {}) unless root

      path = File.join(root, CONFIG_RELATIVE_PATH)
      return RepoConfig.new(root: root, path: path, data: {}) unless File.file?(path)

      parsed = JSON.parse(File.read(path))
      validate_document!(parsed, path)
      RepoConfig.new(root: root, path: path, data: parsed)
    rescue JSON::ParserError => e
      raise ConfigError, "#{path}: malformed JSON: #{e.message}"
    end

    def validate_document!(document, path)
      unless document.is_a?(Hash)
        raise ConfigError, "#{path}: config must be a JSON object"
      end

      return unless document.key?("phase")

      validate_phase!(document["phase"], path)
    end

    def validate_phase!(phase, path)
      unless phase.is_a?(Hash)
        raise ConfigError, "#{path}: $.phase must be an object"
      end

      allowlist = phase["allowlist"]
      unless allowlist.is_a?(Array)
        raise ConfigError, "#{path}: $.phase.allowlist must be an array"
      end

      allowlist.each_with_index do |entry, index|
        next if entry.is_a?(String) && !entry.strip.empty?

        raise ConfigError,
          "#{path}: $.phase.allowlist[#{index}] must be a non-empty string"
      end

      policy = phase["policy"]
      unless PHASE_POLICIES.include?(policy)
        raise ConfigError,
          "#{path}: $.phase.policy must be one of #{PHASE_POLICIES.join(', ')}"
      end
    end
  end
end
