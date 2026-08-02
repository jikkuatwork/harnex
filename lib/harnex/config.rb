require "json"

module Harnex
  module Config
    CONFIG_RELATIVE_PATH = File.join(".harnex", "config.json").freeze
    PHASE_POLICIES = %w[warn reject].freeze
    RETENTION_DIRS = %w[events output].freeze
    RETENTION_FIELDS = %w[max_age_days max_bytes].freeze
    RETENTION_ENV = {
      "events" => {
        "max_age_days" => "HARNEX_EVENTS_MAX_AGE_DAYS",
        "max_bytes" => "HARNEX_EVENTS_MAX_BYTES"
      },
      "output" => {
        "max_age_days" => "HARNEX_OUTPUT_MAX_AGE_DAYS",
        "max_bytes" => "HARNEX_OUTPUT_MAX_BYTES"
      }
    }.freeze
    DEFAULT_RETENTION_LIMITS = RETENTION_DIRS.to_h do |dir|
      [dir, { "max_age_days" => 45, "max_bytes" => 1_073_741_824 }]
    end.freeze

    ConfigError = Class.new(StandardError)

    RepoConfig = Struct.new(:root, :path, :data, keyword_init: true) do
      def present?
        !path.nil? && File.file?(path)
      end

      def phase
        data.is_a?(Hash) ? data["phase"] : nil
      end

      def retention
        data.is_a?(Hash) ? data["retention"] : nil
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

      validate_phase!(document["phase"], path) if document.key?("phase")
      validate_retention!(document["retention"], path) if document.key?("retention")
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

    def retention_limits(start_path = Dir.pwd, env: ENV, config: nil)
      config ||= load_repo(start_path)
      limits = deep_dup_retention_defaults
      retention = config.retention

      if retention
        RETENTION_DIRS.each do |dir|
          next unless retention.key?(dir)

          RETENTION_FIELDS.each do |field|
            next unless retention.fetch(dir).key?(field)

            limits.fetch(dir)[field] = retention.fetch(dir).fetch(field)
          end
        end
      end

      RETENTION_ENV.each do |dir, fields|
        fields.each do |field, name|
          next unless env.key?(name)

          limits.fetch(dir)[field] = parse_positive_integer!(
            env.fetch(name),
            name
          )
        end
      end

      limits
    end

    def validate_retention!(retention, path)
      unless retention.is_a?(Hash)
        raise ConfigError, "#{path}: $.retention must be an object"
      end

      retention.each do |dir, value|
        unless RETENTION_DIRS.include?(dir)
          raise ConfigError,
            "#{path}: $.retention.#{dir} is not supported (expected events or output)"
        end
        unless value.is_a?(Hash)
          raise ConfigError, "#{path}: $.retention.#{dir} must be an object"
        end

        value.each do |field, limit|
          unless RETENTION_FIELDS.include?(field)
            raise ConfigError,
              "#{path}: $.retention.#{dir}.#{field} is not supported"
          end

          parse_positive_integer!(
            limit,
            "#{path}: $.retention.#{dir}.#{field}"
          )
        end
      end
    end

    def parse_positive_integer!(value, label)
      text = value.to_s.strip
      unless text.match?(/\A[0-9]+\z/)
        raise ConfigError, "#{label} must be a positive integer"
      end

      integer = Integer(text)
      raise ConfigError, "#{label} must be a positive integer" if integer <= 0

      integer
    end

    def deep_dup_retention_defaults
      DEFAULT_RETENTION_LIMITS.transform_values(&:dup)
    end
  end
end
