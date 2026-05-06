require_relative "adapters/base"
require_relative "adapters/generic"
require_relative "adapters/codex"
require_relative "adapters/codex_appserver"
require_relative "adapters/claude"

module Harnex
  module Adapters
    module_function

    def known
      registry.keys.sort
    end

    def supported?(key)
      !key.to_s.strip.empty?
    end

    # Phase 1: gated behind HARNEX_CODEX_APPSERVER. Phase 3 flips the
    # default; legacy `Codex` becomes opt-in via `--legacy-pty`.
    def codex_appserver_enabled?
      value = ENV["HARNEX_CODEX_APPSERVER"].to_s.strip.downcase
      %w[1 true yes on].include?(value)
    end

    def build(key, extra_args = [], legacy_pty: false)
      key_str = key.to_s
      if key_str == "codex" && !legacy_pty && codex_appserver_enabled?
        return CodexAppServer.new(extra_args)
      end

      adapter_class = registry[key_str]
      return adapter_class.new(extra_args) if adapter_class

      Generic.new(key_str, extra_args)
    end

    def registry
      @registry ||= {
        "claude" => Claude,
        "codex" => Codex
      }
    end
  end
end
